<img src="banner.png" alt="AXe" width="600"/>

AXe is a comprehensive CLI tool for interacting with iOS Simulators using Apple's HID (Human Interface Device) functionality.

[![CI](https://github.com/cameroncooke/AXe/actions/workflows/release.yml/badge.svg)](https://github.com/cameroncooke/AXe/actions/workflows/release.yml)
[![Licence: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Install

```bash
brew tap cameroncooke/axe
brew install axe
```

Or install in one command:

```bash
brew install cameroncooke/axe/axe
```

Verify the CLI:

```bash
axe --help
axe list-simulators
```

## Xcode compatibility

AXe supports Xcode 26 and Xcode 27. Xcode 27 simulator automation uses Device Hub; Simulator.app is not required.

Release artifacts are built once with the Xcode version selected by the release environment and run unchanged with either supported Xcode selected. Compatibility was validated with Xcode 26.5 (build `17F42`) and iOS 26.5 (`23F77`), and with Xcode 27 Beta 3 (build `27A5218g`) and iOS 27 (`24A5380g`).

AXe builds upstream IDB ([facebook/idb](https://github.com/facebook/idb)) from the immutable revision configured in `scripts/build.sh` and links its libraries statically. The build does not apply a local patch queue. AXe requires macOS 15 or later on Apple silicon.

IDB loads CoreSimulator from the Xcode selected with `xcode-select`; it does not read `DEVELOPER_DIR`. AXe's own `xcrun simctl` calls do honour `DEVELOPER_DIR`, so select the Xcode you want with `xcode-select` rather than overriding it with `DEVELOPER_DIR` alone.

IDB's accessibility service needs its simulator helper, `SimulatorFrameworkBridge-iOS`, from a `Resources/` directory beside the `axe` executable (the release and Homebrew layout). A `swift build` binary finds the checkout's `build_products/idb/bridge` instead; set `AXE_IDB_BRIDGE_DIR` to the directory that contains the helper to use another copy (a relative path resolves against the current directory; AXe fails with an error when the helper is not there).

After some boots, or after an app is terminated and relaunched, the simulator's accessibility service can stop answering for minutes: it names no frontmost application, or returns an empty application element. When an accessibility read (`describe-ui`, selector taps, coordinate taps that read the screen) hits this, AXe restarts the simulator's `com.apple.CoreSimulator.bridge` with `xcrun simctl spawn <UDID> launchctl kickstart -k`, prints a warning on stderr, and retries once. A command (or a whole `batch`) restarts a simulator's bridge at most once; later failures are reported as they are. If the restart itself fails, AXe warns and keeps the original result. Set `AXE_AX_RECOVERY=never` to turn this off.

## E2E development

`make e2e` rebuilds the local IDB libraries (`scripts/build.sh libraries`), builds AXe, and runs the simulator tests with the Xcode selected by `DEVELOPER_DIR` or `xcode-select`. XcodeGen is required to generate the IDB projects. When Xcode 27 is selected, the runner starts Device Hub, chooses an available iOS 27 iPhone 17 Pro, and boots it with `simctl`.

To validate a release payload unchanged under another supported Xcode, first build the test bundle with that Xcode, then run `AXE_BIN_PATH=/path/to/release/axe ./test-runner.sh --tests-only`. The supplied executable must keep its packaged `AXe_AXe.bundle` and `Resources/` beside it.

## Basic usage

```bash
# Find a booted simulator UDID
axe list-simulators
export UDID=<UDID>

# Inspect the current UI
axe describe-ui --udid "$UDID"

# Interact with the simulator
axe tap --label "Continue" --udid "$UDID"
axe type 'Hello world' --udid "$UDID"
axe screenshot --output ./screen.png --udid "$UDID"
```

## Documentation

Full documentation is available at [axe-cli.com/docs](https://axe-cli.com/docs).

## Disclaimer

AXe is an independent open-source iOS Simulator automation project and is not affiliated with, endorsed by, or associated with Deque Systems or its axe® accessibility products.

## Licence

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Third-party licensing notices, including Meta's IDB MIT attribution, are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
