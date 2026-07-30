# Contributing to BambuBar

Thank you for helping improve BambuBar.

## Before opening a change

- search existing issues and pull requests
- keep changes focused and avoid committing printer access codes, real serial numbers or private IP addresses
- use fictional printer data in tests and screenshots

## Build and verify

Requirements: macOS 26 or newer, Swift 6 and Xcode Command Line Tools.

The `Makefile` is the canonical entry point — run `make help` to list every
target. The scripts under `scripts/` remain the implementation, but prefer the
targets so there is one place to change a command. The common ones:

```bash
make check          # self-tests, Keychain variant and the unit suite
make test           # unit tests only (parsers, MQTT codec, discovery)
make app            # package dist/BambuBar.app
make app-keychain   # package "dist/BambuBar Keychain.app"
make run            # package the local-storage variant and launch it
```

`make test` wraps `swift test` and, on Command Line Tools–only machines,
supplies the swift-testing plugin and framework search paths and builds
outside the project tree. With a full Xcode install, plain `swift test` also
works.

Run `make signing` once before your first `make app`. macOS ties the Local
Network privacy grant to the app's code signature, so with ad-hoc signing the
identity changes on every build and the grant — and with it printer access — is
lost. The target creates a stable self-signed identity in your login keychain
and is idempotent.

CI runs `make build`, `make selftest` and `make build-keychain`. The unit suite
is not gated in CI, so run `make check` locally before opening a pull request.

The Keychain storage self-test needs an interactive, unlocked login keychain and is therefore intended for local verification rather than CI.

## Pull requests

Describe what changed, why it is useful and how it was tested. Keep UI changes consistent with the compact native macOS design and include screenshots when the appearance changes.

By contributing, you agree that your contribution is licensed under the MIT License used by this project.
