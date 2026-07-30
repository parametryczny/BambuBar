# AGENTS.md

Guidance for AI coding agents working in this repository. Human-facing docs live in
[README.md](README.md), [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## What this project is

BambuBar is a native macOS **menu bar** app that monitors Bambu Lab 3D printers. It speaks
MQTT over TLS directly to each printer on the local network (port 8883) — there is no cloud
account, no backend, and no telemetry leaving the machine.

- **Swift 6** (strict concurrency), SwiftPM executable target, **macOS 26+**
- **AppKit**, built entirely in code — no `.xib`, no `.storyboard`, no SwiftUI
- **Zero third-party dependencies.** `Package.swift` has no `dependencies:` array and should
  keep it that way. MQTT framing, SSDP, subnet probing and certificate pinning are all
  hand-rolled on `Darwin` / `Network` / `Security` / `CryptoKit`.

## Commands

```bash
swift build --disable-sandbox              # standard build (the flag is required here)

.build/debug/BambuBar --self-test           # protocol parsers; this is what CI gates on
.build/debug/BambuBar --storage-self-test   # access-code round-trip for the active backend
.build/debug/BambuBar --certificate-pin-self-test
.build/debug/BambuBar --scan                # print printers found on the LAN, then exit

./scripts/run-tests.sh                      # unit tests — use this, not bare `swift test`
./scripts/build-app.sh local                # → dist/BambuBar.app
./scripts/build-app.sh keychain             # → dist/BambuBar Keychain.app
./scripts/build-release.sh                  # both .app bundles + both release ZIPs
./scripts/setup-signing.sh                  # once per machine, see "Code signing" below
```

`run-tests.sh` wraps `swift test` because on Command Line Tools–only machines the
swift-testing macro plugin and framework are off the default search paths, and building
inside an iCloud-synced folder makes `codesign` reject the `.xctest` bundle on Finder
metadata. It adds the plugin paths and a scratch path outside the tree.

Run the flag self-tests before finishing any change to parsing, framing, storage or pinning.

## Layout

```
Sources/BambuBar/
  App/          BambuBarApp (@main), PrinterStore (state), AppSettings (language/theme)
  Models/       Printer.swift — every model type, all Sendable
  Services/     network, parsing, storage — no AppKit imports here
  Views/        AppKit controllers and custom views, all @MainActor
  Diagnostics/  ProtocolSelfTest — compiled into the shipping binary
Tests/BambuBarTests/   swift-testing suites for pure logic
Resources/      Info.plist, BambuBar.entitlements
scripts/        build, release, signing, test wrappers (zsh)
```

### Data flow

`SSDPDiscovery` + `BambuSubnetDiscovery` (run concurrently, deduped by serial)
→ `DiscoveredPrinter` → `PrinterStore.upsert` → `AccessCodeStore` + `PrinterPersistence`
→ one `MQTTClient` per printer, each on its own serial `DispatchQueue`
→ `MQTTCodec.extractPackets` → `BambuStatusParser.telemetry`
→ `MQTTClient.Event` → hop to `@MainActor` → `PrinterStore.handle`
→ `@Published` → Combine `objectWillChange` → dashboard refresh (60 ms debounce).

`PrinterStore` is the single source of truth. Views never talk to services directly; they
receive closures (`onEdit`, `onReconnect`, `onMove`, …) from `MenuBarController`.

## Conventions that are easy to get wrong

### Localization is hand-rolled, Polish first

There is no `.strings` file and no `NSLocalizedString`. Every user-facing string goes
through `AppSettings.shared.text("polski", "english")` — **Polish argument first**.

- Windows are built once and reused (`isReleasedWhenClosed = false`), so language-dependent
  strings must be **reapplied on every open**, not just at construction. See
  `AddPrinterWindowController.localize()`, called from `prepareForAdding` /
  `prepareForEditing`. Forgetting this leaves a stale-language form.
- `PrinterState.label` in `Models/Printer.swift` returns **Polish only** and is not
  localized. In UI code use `AppSettings.stateLabel(_:)` or
  `AppSettings.activityLabel(stage:state:)` instead.
- Errors thrown from `Services/` (`ValidationError`, `AccessCodeStoreError`,
  `BambuStudioConfigError`, `LaunchAtLoginError`) carry **Polish-only** messages and are
  displayed verbatim via `error.localizedDescription`. Match that existing behaviour unless
  you are deliberately fixing it across the board.
- `CHANGELOG.md`, the shell scripts' output, and the app's Edit menu are Polish-only.

### Two build variants from one source tree

`-DKEYCHAIN_STORAGE` selects the Keychain access-code backend. `AccessCodeStore` is the
**only** file with an `#if KEYCHAIN_STORAGE` split. Both branches must always compile — CI
builds the variant explicitly. Note `AccessCodeStoreError.keychain` exists only under the
flag, so any `switch` over that enum needs matching `#if` fencing.

| | Local build | Keychain build |
|---|---|---|
| Bundle ID | `pl.bambubar.app` | `pl.bambubar.app.keychain` |
| Codes stored in | app preferences | macOS Keychain (`kSecClassGenericPassword`) |
| `AccessCodeStore.modeName` | `"Local"` | `"Keychain"` |

### Always use `BambuDefaults.shared`, never `UserDefaults.standard`

The Keychain build deliberately opens the `pl.bambubar.app` suite rather than its own
domain, so both variants share printers, ordering, certificate pins and settings. Going
through `UserDefaults.standard` silently breaks that for one variant.

Keys currently in use — version-suffix any new one the same way:
`saved-printers-v1`, `printer-access-codes-local-v1`, `printer-certificate-pins-v1`,
`app-language`, `app-theme`, `dashboard-compact-mode`.

### Concurrency

- `@MainActor`: `BambuBarApp`, `PrinterStore`, `AppSettings`, `AccessCodeStore`,
  `HMSResolver`, and every type in `Views/`.
- Networking types are `final class … : @unchecked Sendable` guarding their state with a
  private serial `DispatchQueue` or an `NSLock` — `MQTTClient`, `SSDPDiscovery`,
  `BambuSubnetDiscovery`, `CertificatePinStore`, `LocalNetworkPermissionPrompter`, `ProbeBox`.
- `MQTTClient` invokes its `onEvent` callback on its own queue. Callers hop explicitly:
  `Task { @MainActor [weak self] in … }`. Keep that hop when adding events.
- All model types in `Models/Printer.swift` are `Sendable`.

### Printer-supplied strings need Unicode repair

Printers send NFD, percent-encoding, and occasionally UTF-8 mis-decoded as CP1252.
`BambuStatusParser.displayName` repairs all three; `PrinterStore` applies
`.precomposedStringWithCanonicalMapping` to discovered names. Apply the same treatment to
any new string that originates from a printer or from Bambu Studio's config.

### The telemetry parser merges, it does not rebuild

`BambuStatusParser.telemetry(from:previous:)` starts from `previous` and assigns a field
**only when the JSON key is present**:

```swift
if let value = integer(report["mc_percent"]) { result.progress = min(max(value, 0), 100) }
```

Printers push partial reports, so an unconditional `result.progress = integer(...) ?? 0`
would blank live fields between updates. Keep the `if let` shape. The function returns `nil`
for JSON that is not a `print` / `pushing` report so unrelated messages are ignored.

### Discovery has two independent paths, and both have tuned constants

`PrinterStore.scan()` races `SSDPDiscovery` and `BambuSubnetDiscovery` and merges by serial.
They fail in different ways, which is the point of having both:

- **`SSDPDiscovery`** binds UDP **2021** (Bambu's announcement port) and multicasts an
  `M-SEARCH`. If 2021 is already held — Bambu Studio running, which does not share the port —
  it falls back to an **ephemeral port**; the unicast replies to our own `M-SEARCH` still
  come back. Without that fallback, discovery silently returns nothing whenever Bambu Studio
  is open. Do not "simplify" the bind back to a single attempt.
- **`BambuSubnetDiscovery`** brute-forces the local /24 on 8883 and reads the serial from the
  TLS certificate's subject CN. Its two constants are load-bearing for scan latency:
  **128** concurrent probes and a **2.0 s** per-host timeout. At the earlier 32 / 3.5 s a
  full scan took ~30 s and tripped the 8 s watchdog in `PrinterStore.scan()`; that watchdog
  is still present, so raising the timeout or lowering concurrency will resurrect spurious
  "scan exceeded 8 seconds" errors.

`BambuStudioConfig.devices()` returns serial + access code + last known `ip_address` from
Bambu Studio's config, so **import does not require a network scan** — it works on a clean
install with no saved printers. `importFromBambuStudio` prefers a live address (saved printer,
then fresh discovery hit) and only falls back to the config's IP. The older
`accessCodes()` helper is now a thin wrapper over `devices()`.

### macOS 26 baseline, no back-deployment

`PrinterCardView` and `CompactPrinterRowView` subclass `NSGlassEffectView`, which is
macOS 26 API. This codebase carries no `@available` guards or fallback paths, and
`Package.swift` / `Info.plist` both pin 26.0.

### AppKit house style

`NSStackView` + `NSGridView` + Auto Layout anchors; `required init?(coder:) { nil }`;
`private final class` for view subclasses local to a file; `enum` as a namespace for
stateless helpers (`MQTTCodec`, `BambuStatusParser`, `SSDPResponseParser`, `NotificationService`,
`BambuDefaults`, `LaunchAtLoginManager`, `BambuStudioConfig`, `ProtocolSelfTest`).
Prefer `guard … else { return }` early exits and implicit-return `switch` expressions —
both are used consistently throughout.

## Testing

Two tiers, and the distinction matters:

1. **`Tests/BambuBarTests/`** — swift-testing (`@Suite`, `@Test`, `#expect`) covering pure
   logic: `MQTTCodec`, `SSDPResponseParser`, `BambuStatusParser`. Run via
   `./scripts/run-tests.sh`. **CI does not run these.**
2. **`Diagnostics/ProtocolSelfTest.swift`** — compiled into the shipping binary, run with
   `--self-test`. **This is the tier CI gates on.**

So a protocol- or parser-level change should get a check in *both* places, or a regression
can pass CI. `ProtocolSelfTest` returns a `[String]` of failure descriptions; append to
`failures` rather than asserting.

CI (`.github/workflows/ci.yml`, `macos-26`) runs: build → `--self-test` →
`--storage-self-test` → `--certificate-pin-self-test` → compile the Keychain variant. The
storage self-test there exercises the **Local** backend only; the Keychain path needs an
unlocked interactive login keychain and is a local-verification step.

Test fixtures use fictional data — serial `01S00A123456789`, host `192.168.1.42`. Keep it
that way.

## Security invariants

Read [SECURITY.md](SECURITY.md) for the full trust model. When editing, preserve these:

- **TOFU certificate pinning.** Bambu printers present device-local certificates with no
  path to a public root. `CertificatePinStore.validate` records the first SHA-256 fingerprint
  per serial and returns `.mismatch` afterwards if it changes; `ValidationResult.accepted`
  is `!= .mismatch`, and `MQTTClient`'s verify block must keep failing the handshake on a
  mismatch. Removing a printer clears its pin — that is the intended, user-driven escape
  hatch for legitimate firmware certificate rotation.
- **Never log access codes.** `MQTTClient` logs disconnect reasons with `privacy: .private`
  and only CONNACK result codes as `.public`. Keep new log sites just as careful.
- **Never commit real serials, access codes or LAN IP addresses** — not in code, tests,
  fixtures, screenshots or commit messages.
- **No network traffic to anything but the printer.** `BambuSubnetDiscovery` probes the
  local /24 on 8883 only. Do not add analytics, crash reporting or update checks.
- **Bambu Studio config is read only on explicit user action** — the *Import printers and
  codes* button, never at launch.
- `NotificationService` shells out to `osascript`; `escaped()` is what stops AppleScript
  string injection from printer-supplied job names. Do not bypass it.

## Code signing and the Local Network permission

macOS ties the Local Network privacy grant to the app's **code signature**. Ad-hoc signing
(`codesign --sign -`) produces a new identity on every build, so the grant is lost and the
app can no longer reach printers. `scripts/setup-signing.sh` creates a stable, self-signed
(and deliberately untrusted) identity named `BambuBar Local Signing` in the login keychain;
`build-app.sh` prefers it and warns when falling back to ad-hoc. Run it once per machine.

`LocalNetworkPermissionPrompter` starts a declared Bonjour browser (`_bambubar._tcp`,
matching `NSBonjourServices` in `Info.plist`) because that is Apple's supported way to raise
the permission prompt before direct-IP connections are attempted.

## Versioning and release

`Resources/Info.plist` → `CFBundleShortVersionString` is the source of truth;
`build-release.sh` reads it to name the ZIPs. A version bump needs **four** places moved
together:

1. `Resources/Info.plist` — `CFBundleShortVersionString` **and** `CFBundleVersion`
   (since 0.1.18 both carry the same `X.Y.Z` string; `CFBundleVersion` used to be a
   separate build counter)
2. `CHANGELOG.md` — new `## X.Y.Z — YYYY-MM-DD` section (Polish, lowercase bullets, newest first)
3. `README.md` — the "Latest changes" / "Najnowsze zmiany" paragraph, both languages
4. `Sources/BambuBar/Views/SettingsWindowController.swift` — the hardcoded fallback string
   in `refresh()`

These drift in practice: the 0.1.18 release commit moved only (1) and (2). Treat
`Info.plist` as authoritative and do not trust the README or the Settings fallback as a
version reference. `Info.plist` is Xcode-normalised — tab-indented, one key per line,
alphabetically sorted — so match that layout rather than the old compact
`<key>x</key><string>y</string>` style.

## Working agreements

- Keep changes focused; this is a small codebase with no abstraction layer to hide behind.
- Match the surrounding comment density — comments here are sparse and explain *why*
  (protocol quirks, macOS behaviour), never *what*.
- Do not add dependencies, a package manager, a linter config, or a build system without
  being asked.
- UI changes should stay consistent with the compact native macOS look; include a screenshot
  in the PR when appearance changes.
- Both languages, always: a new user-facing string without its Polish or English half is an
  incomplete change.
