# CLAUDE.md

@AGENTS.md

The file above is the canonical guide for this repository — architecture, conventions,
security invariants and release process. Everything below is specific to working here with
Claude Code.

## Verify before you report done

```bash
swift build --disable-sandbox && \
  .build/debug/BambuBar --self-test && \
  .build/debug/BambuBar --certificate-pin-self-test && \
  ./scripts/run-tests.sh
```

Add `swift build --disable-sandbox -Xswiftc -DKEYCHAIN_STORAGE` whenever you touch
`Services/AccessCodeStore.swift` or anything it references — that variant is compiled in CI
and a `#if` mistake will not show up in a default build.

A clean build takes well under a minute, so run the full loop rather than reasoning about
whether a change could have broken something.

## Do not launch the GUI to check a change

BambuBar is an `LSUIElement` accessory app: launching it produces no window, only a menu bar
item you cannot see or click from a tool call, and it leaves a background process holding
sockets. It also needs real printers on the LAN plus a Local Network grant to do anything
interesting.

Use the CLI entry points in `BambuBarApp.main()` instead — they run before
`NSApplication.shared` is touched and exit on their own:

| Flag | Checks |
|---|---|
| `--self-test` | SSDP parsing, telemetry parsing, AMS layouts, MQTT framing |
| `--storage-self-test` | access-code save / read / delete round-trip |
| `--certificate-pin-self-test` | TOFU state machine: first use → match → mismatch |
| `--scan` | live LAN discovery; needs real printers and the Local Network grant |

`--storage-self-test` on a `-DKEYCHAIN_STORAGE` build will try to touch the login keychain
and may prompt or fail in a non-interactive session — that one is for a human at the machine.

If a change genuinely needs visual confirmation, build the bundle
(`./scripts/build-app.sh local`) and ask the user to run it and report back.

## Reading the code

The whole source tree is ~3,750 lines across 24 files, so prefer reading files directly over
broad searches. The only large file is
`Sources/BambuBar/Views/PrinterDashboardViewController.swift` (~1,120 lines), which holds the
view controller plus eight `private final class` view types — `CompactPrinterRowView`,
`PrinterCardView`, `PrinterDragHandle`, `CardActionsButton`, `CompactMetricView`,
`BrutalistProgressView`, `AMSSlotView`, `ClosureButton`. Grep for `private final class` in
that file to jump between them.

## When editing user-facing strings

Every string needs both languages via `AppSettings.shared.text("polski", "english")`. After
adding one, confirm the surrounding window reapplies it on open rather than only at
construction — see the localization notes in AGENTS.md. `grep -n 'settings.text(\|\.text("'`
across `Sources/BambuBar/Views/` shows the established pattern.

## Repository facts

- `.build/` and `dist/` are gitignored; never add build output to a commit.
- Scripts are `zsh` with `set -euo pipefail` and resolve their own project root via
  `${0:A:h:h}` — they can be invoked from any working directory.
- Commit messages in this repo are short, imperative, sentence-case English
  (`Localize the Add/Edit printer window on every open`). `CHANGELOG.md` entries are Polish.
- Default branch is `main`; open pull requests against it.
