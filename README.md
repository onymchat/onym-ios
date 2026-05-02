# OnymIOS

iOS app for Onym, built incrementally on top of
[`onym-sdk-swift`](https://github.com/onymchat/onym-sdk-swift).

This repo is being grown from scratch — small, hand-reviewable chunks.
The first chunk (this initial state) just wires in the OnymSDK Swift
Package.

## Setup

```sh
brew install xcodegen
./generate-xcodeproj.sh
open OnymIOS.xcodeproj
```

`project.yml` is the source of truth for the Xcode project.
`*.xcodeproj/` is gitignored so we never deal with `pbxproj` merge
conflicts. Re-run `./generate-xcodeproj.sh` after pulling, or any
time `project.yml` changes.

## Architecture (target shape)

> **Not landed yet.** First chunk is just SDK wiring with one smoke
> view. The architecture skeleton lands in a later chunk where there's
> real domain logic to model.

When it does land:

- **Repositories** own all I/O — keychain, network, on-device
  state. Pure references; no UI.
- **Unidirectional reactive flow to views** — repositories publish
  state; views observe and render; user actions flow back as
  intents that mutate repository state. No bidirectional bindings,
  no shared mutable state across views.
- **OnymSDK is internal-only** — repositories wrap it; views never
  call it directly.

## Current state

```
.
├── project.yml                 ← xcodegen source of truth
├── generate-xcodeproj.sh       ← regenerates OnymIOS.xcodeproj
├── Sources/
│   └── OnymIOS/
│       ├── OnymIOSApp.swift          ← @main
│       └── SDKWiringSmokeView.swift  ← one OnymSDK call to verify wiring
└── README.md
```

## Build status — blocked on upstream

Adding the SPM dep on `onym-sdk-swift` from `0.0.1` resolves cleanly,
but `xcodebuild` errors:

```
error: The package product 'OnymSDK' cannot be used as a dependency
of this target because it uses unsafe build flags.
```

`v0.0.1` tagged the **dev-loop** variant of `Package.swift` (with
`linkerSettings: [.unsafeFlags(["-L./build/host", ...])]` to link the
host-built Rust staticlibs). SPM refuses to consume packages with
unsafe flags as dependencies — that's the intended SPM safety gate.

The fix lives in
[`onymchat/onym-sdk-swift#2`](https://github.com/onymchat/onym-sdk-swift/pull/2)
— that PR adds a `Release` workflow that builds an `XCFramework` and
tags a release-variant `Package.swift` consuming it via
`.binaryTarget(url:checksum:)`. Once that PR merges and the workflow
runs (`gh workflow run Release -f tag=v0.0.x`), this repo's build
will go green.

In the meantime, the wiring (project.yml + Swift sources) is
structurally correct and ready for review.

## Versioning

This repo will track `OnymSDK` at `from: "0.0.1"`. Until the SDK hits
1.0, breaking changes can land in any minor bump — pin to a specific
version (`exact: "X.Y.Z"`) if reproducibility matters more than
auto-upgrade.

## License

MIT — see `LICENSE`.
