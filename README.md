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

IDB loads CoreSimulator from the Xcode selected with `xcode-select`; it does not read `DEVELOPER_DIR`. AXe's own `xcrun` calls (`simctl`, `devicectl`) do honour `DEVELOPER_DIR`, so select the Xcode you want with `xcode-select` rather than overriding it with `DEVELOPER_DIR` alone.

IDB's accessibility service needs its simulator helper, `SimulatorFrameworkBridge-iOS`, from a `Resources/` directory beside the `axe` executable (the release and Homebrew layout). A `swift build` binary finds the checkout's `build_products/idb/bridge` instead; set `AXE_IDB_BRIDGE_DIR` to the directory that contains the helper to use another copy (a relative path resolves against the current directory; AXe fails with an error when the helper is not there).

After some boots, or after an app is terminated and relaunched, the simulator's accessibility service can stop answering for minutes: it names no frontmost application, or returns an empty application element. When an accessibility read (`describe-ui`, selector taps, coordinate taps that read the screen) hits this, AXe restarts the simulator's `com.apple.CoreSimulator.bridge` with `xcrun simctl spawn <UDID> launchctl kickstart -k`, prints a warning on stderr, and retries once. A command (or a whole `batch`) restarts a simulator's bridge at most once; later failures are reported as they are. If the restart itself fails, AXe warns and keeps the original result. Set `AXE_AX_RECOVERY=never` to turn this off.

### Foldable simulators

On foldable simulators (iPhone Duo, Xcode 27.1 or later), AXe reads which display is active from the simulator through IDB, in process, once any fold or rotation has settled. Only `xcrun devicectl device info displays` reports the numeric display IDs (1 cover, 3 inner) that AXe prints and accepts in `--display`; AXe reads them once per device and caches them in `~/Library/Caches/AXe/display-ids` (a failed read is not repeated within the same command; displays are then named by name and unique ID, so pass `--display cover|inner` or a name). `axe posture` reads devicectl every time for the backlight and device orientation; when devicectl fails it prints the displays IDB reports, with a warning, and the backlight and device orientation as unknown. A display state that is still changing after 10 s (a fold that has not settled) is never used: the command fails and asks to retry. Other simulators never run this probe; set `AXE_DISPLAY_PROBE=always` or `AXE_DISPLAY_PROBE=never` to override. IDB routes touches to the active display whatever the probe policy, so raw `-x/-y` coordinates stay correct with `never`. `never` does disable AXe's own display handling: the out-of-display refusal, `--display cover|inner`, and the active-display filtering of `describe-ui`, selector taps (`--id`, `--label`, `--value`), `slider` and `gesture` presets. With the inner display active, home-screen (SpringBoard) frames then stay in the panel's native portrait points, so selector taps there can land in the wrong place; AXe prints a one-time warning on a foldable when the probe is disabled. Do not set `never` on a foldable.

- `axe screenshot` captures the active display by default, through IDB, rotated to its current UI orientation. Use `--display cover`, `--display inner`, a display ID, or a display name to pick one; AXe captures those with `xcrun simctl io`, which can also capture an inactive display (with a warning: it may be black).
- Touch commands (`tap`, `swipe`, `drag`, `gesture`, `slider`, `touch`, and batch steps) follow the active display, folded or unfolded. Coordinates are interface points of the active display, as `axe screenshot` shows it (pixels divided by the scale, 3 on the iPhone Duo): the unfolded inner display in landscape is 951x669 points. IDB converts them to the display's native orientation; a point outside the display fails without sending anything. Touches fail with an error only when the active display cannot be determined, or when the inner display is active and the simulator uses the legacy Indigo input transport.
- The first touch of a command waits until IDB has confirmed the simulator's input session is live.
- `axe hinge close|open|half|set <degrees>` folds and unfolds the simulator. On iOS 27.2 and later runtimes AXe sets the angle directly (a 0-180 jump switches displays reliably there), or sweeps it over `--duration`; on older runtimes every change sweeps from the current angle (from the opposite end when the angle cannot be read) over at least 0.4 s, because a direct jump left iOS 27.1 unable to switch displays. AXe then confirms the angle the simulator reports and waits up to 8 s for the cover (at most 30 degrees) or inner (at least 120 degrees) display to become active and lit; `--no-wait` skips that wait, and the printed posture may still be changing. `axe hinge sweep <from> <to>` always sweeps, over at least 0.4 s, and first moves to `<from>` when the hinge is elsewhere. `axe hinge get` prints the angle. Hinge commands fail at once on simulators that report no hinge.
- `axe posture` prints the hinge angle, the active display, and each display's rotation, interface orientation and size in points; add `--json` for scripts. Check it after every fold: the angle and the active display are separate states.
- `axe rotate portrait|landscape|portrait-upside-down|landscape-flipped` rotates the interface of the active display and verifies the display rotation. It also works on other simulators, where it sets the matching device orientation (landscape is device `landscapeRight`); when the foreground app or screen does not rotate (for example an iPhone home screen), it prints a warning instead of "Rotated to".
- `axe record-video` records the active display by default and takes the same `--display` values as `screenshot`. On a foldable, or with an explicit `--display`, AXe records with `xcrun simctl io recordVideo`: H.264 at the display's native size, a frame each time the display changes, rotated to its UI orientation on playback, remuxed to MP4 (a `.mov` output keeps simctl's QuickTime file). simctl has no frame-rate, bitrate or scaling control, so `--fps`, `--quality` and `--scale` other than 1.0 fail there. The display is chosen when the recording starts; folding mid-recording does not switch it. An explicitly chosen display that is inactive records black, with a warning. simctl runs in AXe's process group, so Ctrl+C in a terminal stops both; if AXe itself is killed with SIGKILL, simctl keeps recording until it is stopped, and its hidden `.axe-recording-*.mov` file is removed by the next recording into that directory once it is an hour old.
- `axe stream-video` streams the active display: the cover while folded, the inner display while unfolded. `--display auto` (the default) follows it; `--display cover`, `--display inner`, an ID or a name is accepted only while that display is active, and fails otherwise (use `record-video --display` or `screenshot --display` to capture an inactive display).
- `describe-ui` with the inner display active reports only that display's windows, with every `frame` and `AXFrame` in its interface points (the same space as touch coordinates and `axe screenshot`), so home-screen labels appear once. The JSON schema is unchanged. `describe-ui --point X,Y` takes interface points of the inner display; AXe hit-tests the reported tree and prints that element in the usual shape: windows are searched front to back (AXe takes later windows in the tree to be in front), and within a window the deepest element containing the point wins, preferring one with a label or value over one with only an identifier. If AXe cannot determine the active display (for example the display read fails), `describe-ui` prints a warning on stderr and the unfiltered tree. `--all-displays` prints the tree as the simulator reports it, without AXe's filtering and conversion: IDB already limits it to the active display, so labels appear once, but the application frame is the cover's size and SpringBoard frames are in the inner display's native portrait points; `--point` then uses the simulator's own hit test, which also takes interface points of the active display. With the cover active, and on other simulators, `describe-ui` output is unchanged. On the folded cover, home-screen frames can differ from the visible layout. Verify state with `axe screenshot` (the active display, rotated to its UI orientation) and `axe posture`.
- Hinge and rotation use Device Hub's private events, sent and read back through IDB. If the active display stops following the hinge, shut the simulator down and boot it again.

```bash
axe hinge close --udid "$UDID"          # fold: the cover display becomes active
axe posture --udid "$UDID"              # angle, active display, orientation, size
axe screenshot --output ./cover.png --udid "$UDID"
axe record-video --output ./cover.mp4 --udid "$UDID"   # records the cover until Ctrl+C
axe tap -x 200 -y 300 --udid "$UDID"   # taps the cover
axe hinge open --udid "$UDID"           # unfold flat: the inner display becomes active
axe tap --label Settings --udid "$UDID" # taps the inner display
axe describe-ui --point 763,389 --udid "$UDID"   # element at an inner-display interface point
axe rotate portrait --udid "$UDID"      # rotate the active display's interface
```

## Platforms

`axe list-simulators` ends each line with the simulator's platform (`Platform 'iOS'`, `watchOS`, `tvOS`, `visionOS` or `unknown`; iPad simulators report `iOS`, and `unknown` is a platform AXe does not recognise, handled like iOS). AXe is built for iOS; on the other platforms commands that cannot work fail before anything is sent, with a message saying why. Probed on Xcode 27.2 with watchOS 27.2 and visionOS 27.2 runtimes; tvOS is from code reading only.

| Command | watchOS | tvOS | visionOS |
|---|---|---|---|
| `list-simulators`, `screenshot`, `record-video`, `stream-video`, `posture` | yes | yes (untested) | yes |
| `tap -x -y`, `swipe`, `drag`, `touch`, `gesture` | yes (coordinates pass through; `gesture` presets fit the watch screen) | refused: use `axe remote` | refused |
| `tap`/`slider` with `--id`, `--label`, `--value` | fails: the accessibility tree is only an empty root | refused | refused |
| `describe-ui` | root element only; `--point` works | untested | partial skeleton |
| `button` | `home` (Digital Crown press), `side-button`, `lock`, `siri` | `play-pause`, `volume-up`, `volume-down` | refused |
| `remote up\|down\|left\|right\|select\|menu\|play-pause` | refused | yes | refused |
| `type`, `key`, `key-sequence`, `key-combo` | sent, delivery unverified | expected to work (focus) | refused |
| `rotate`, `hinge` | refused (iOS only) | refused | refused |
| `batch` | as the single commands | as the single commands | refused |

visionOS input is refused because IDB v1.7.7 drives only the touch digitizer service, which visionOS does not provide. Digital Crown rotation, the Siri Remote trackpad and visionOS pointer, gaze and hand input are not available.

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

Third-party licensing notices, including Meta's IDB MIT attribution, are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
