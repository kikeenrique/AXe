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

AXe builds IDB from the immutable fork revision configured in `scripts/build.sh`, based on a verified upstream IDB revision. The build does not apply a local patch queue.

### Foldable simulators

On foldable simulators (iPhone Duo, Xcode 27.1 or later), AXe reads which display is active with `xcrun devicectl device info displays`. Other simulators never run this probe; set `AXE_DISPLAY_PROBE=always` or `AXE_DISPLAY_PROBE=never` to override.

- `axe screenshot` captures the active display by default. Use `--display cover`, `--display inner`, a display ID, or a display name to pick one. simctl returns the captured display rotated to its current UI orientation.
- While the inner display is active, touch commands fail with an error, because AXe cannot deliver touches to the inner display yet. Keyboard, text, and hardware-button commands are not affected.
- While the cover display is active, use `--tap-style physical` for `tap` (and batch-level `--tap-style physical`). Default-style taps (simulator `tapAt`) exit 0 without any effect on the folded cover, on the home screen and inside apps; physical touch down/up works. The cause is not known yet.
- `axe hinge close|open|half|set <degrees>` folds and unfolds the simulator. Each change sweeps from the current angle (from the opposite end when the angle cannot be read), confirms the angle the simulator reports, and waits up to 8 s for the cover (at most 30 degrees) or inner (at least 120 degrees) display to become active. `axe hinge sweep <from> <to>` first sweeps to `<from>` when the hinge is elsewhere. `axe hinge get` prints the angle. Hinge commands fail at once on simulators without a hinge.
- `axe posture` prints the hinge angle, the active display, and each display's rotation, interface orientation and size in points; add `--json` for scripts. Check it after every fold: the angle and the active display are separate states.
- `axe rotate portrait|landscape|portrait-upside-down|landscape-flipped` rotates the interface of the active display and verifies the display rotation. It also works on other simulators through `devicectl device orientation set`; when the foreground app or screen does not rotate (for example an iPhone home screen), it prints a warning instead of "Rotated to".
- `record-video` and `stream-video` still capture the inner display's framebuffer, so they record a black or wrong display while folded.
- `describe-ui` on the inner display reports the windows of both displays, with frames in the inner display's native portrait points, and every home-screen label or identifier matches twice. `describe-ui --point` hit-tests the cover display only. On the folded cover, home-screen frames can also differ from the visible layout. Verify state with `axe screenshot` (the active display, rotated to its UI orientation) and `axe posture`.
- Hinge and rotation use private Device Hub events through a small helper that AXe compiles on first use with the selected Xcode and caches in `~/Library/Caches/AXe/sim-helper`. If the active display stops following the hinge, shut the simulator down and boot it again.

```bash
axe hinge close --udid "$UDID"          # fold: the cover display becomes active
axe posture --udid "$UDID"              # angle, active display, orientation, size
axe screenshot --output ./cover.png --udid "$UDID"
axe tap -x 200 -y 300 --tap-style physical --udid "$UDID"   # taps on the cover: physical style
axe hinge open --udid "$UDID"           # unfold flat: the inner display becomes active
axe rotate portrait --udid "$UDID"      # rotate the active display's interface
```

## E2E development

`make e2e` rebuilds the local IDB XCFrameworks, builds AXe, and runs the simulator tests with the Xcode selected by `DEVELOPER_DIR` or `xcode-select`. XcodeGen is required to generate the IDB projects. When Xcode 27 is selected, the runner starts Device Hub, chooses an available iOS 27 iPhone 17 Pro, and boots it with `simctl`.

To validate a release payload unchanged under another supported Xcode, first build the test bundle with that Xcode, then run `AXE_BIN_PATH=/path/to/release/axe ./test-runner.sh --tests-only`. The supplied executable must retain its packaged frameworks beside it.

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
axe screenshot --display cover --output ./cover.png --udid "$UDID"   # foldable: pick a display

# Foldable and orientation state
axe hinge close --udid "$UDID"
axe posture --json --udid "$UDID"
axe rotate landscape --udid "$UDID"
```

## Documentation

Full documentation is available at [axe-cli.com/docs](https://axe-cli.com/docs).

## Disclaimer

AXe is an independent open-source iOS Simulator automation project and is not affiliated with, endorsed by, or associated with Deque Systems or its axe® accessibility products.

## Licence

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Third-party licensing notices, including Meta's IDB MIT attribution and the MIT notices of hinge and duoctl (the basis of the foldable helper), are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
