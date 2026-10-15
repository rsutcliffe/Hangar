<p align="center"><img src="docs/icon.png" width="128" alt="Hangar app icon"></p>

# Hangar

A small macOS app (SwiftUI, Liquid Glass, macOS 26+) that shows the state of self-hosted GitHub Actions runners running in Colima VMs: runner and VM health, current job and step progress, CPU and memory load, stalls and failures, and the shared job queue. Stalls and failures raise a macOS notification. Each runner can be restarted or drained from the window.

## Build

Requires Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [Colima](https://github.com/abiosoft/colima).

```bash
cp Local.xcconfig.example Local.xcconfig   # then set your bundle id / team (file is gitignored)
xcodegen generate
open Hangar.xcodeproj
```

The app is not sandboxed because it runs the `colima` CLI.

## Configure

Open Settings (⌘,): GitHub org or user, repos, Colima profile names (one per runner), runner directory inside the VM, stall threshold and poll interval.

The GitHub token (fine-grained, `actions:read`) is stored in the macOS Keychain only. It is never written to disk, defaults or logs, and nothing secret lives in this repository.

## Demo mode

`Hangar --demo` shows scripted data with no token or VMs. Extra flags: `--scenario-failed`, `--scenario-restarting`, `--scenario-paused`, and `--light` / `--dark` to force an appearance.

## Tests

```bash
xcodebuild -project Hangar.xcodeproj -scheme Hangar test CODE_SIGNING_ALLOWED=NO
```

## Licence

Hangar is open source under the [Apache License 2.0](LICENSE). You may use, modify and redistribute it, including commercially, provided that you:

- keep the [LICENSE](LICENSE) and [NOTICE](NOTICE) files, so the original project and its author stay credited in your fork or product;
- mark any files you changed;
- do not use the Hangar name or icon to suggest your version is the original or endorsed by the author.

The licence grants no rights to the Hangar name or icon beyond describing where your work came from.
