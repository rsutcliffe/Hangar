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

`Hangar --demo` shows scripted data with no token or VMs. Extra flags: `--scenario-failed`, `--scenario-restarting`, `--scenario-paused`.

## Tests

```bash
xcodebuild -project Hangar.xcodeproj -scheme Hangar test CODE_SIGNING_ALLOWED=NO
```
