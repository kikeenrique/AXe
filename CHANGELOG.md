# Changelog

All notable changes to the AXe iOS testing framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added `axe screenshot --display auto|cover|inner|<id>|<name>` to choose the captured display. `auto` (default) captures the active display through IDB once any fold has settled; `cover`, `inner`, an ID or a name are captured with `xcrun simctl io` and can capture an inactive display. On foldable simulators (iPhone Duo) the display state is read from the simulator through IDB; non-foldable simulators are not probed. devicectl is read only for the numeric display IDs (1 cover, 3 inner), once per device, cached in `~/Library/Caches/AXe/display-ids`; a failed read is not repeated within the same command, and the displays are then named by name and unique ID. A display state that is still changing (a fold that has not settled within 10 s) is never used. Set `AXE_DISPLAY_PROBE=auto|always|never` to override when display detection runs.
- Added `axe hinge set|open|close|half|sweep|get` for foldable simulators (iPhone Duo, Xcode 27.1 or later), on IDB's hinge commands. On iOS 27.2 and later runtimes the angle is set directly (a direct 0-180 change switched displays 5 times out of 5 there) or swept over `--duration`; older runtimes always sweep from the current angle, since an instant jump left iOS 27.1 unable to switch displays. `hinge sweep` always sweeps. A sweep never moves the hinge more than 10 degrees per step, so a slow host lengthens it instead of turning it into jumps. AXe confirms the angle the simulator reports and waits for the cover or inner display to become active and lit; with `--no-wait` the printed posture is read at once and may still be changing. Hinge support is detected from the simulator's reported capabilities.
- Added `axe posture` to print the hinge angle, the active display, and each display's rotation, interface orientation and size in points, as text or `--json`. Works on any simulator; the hinge angle is `null` without a hinge. The hinge angle, activity, rotation and size come from IDB; display IDs, backlight and device orientation from `xcrun devicectl`, read concurrently. When devicectl fails, `posture` prints the displays IDB reports with a warning, and the backlight and device orientation as unknown.
- Added `axe rotate portrait|landscape|portrait-upside-down|landscape-flipped` to rotate the interface of the active display through IDB's orientation commands, verified by the display rotation the simulator reports. On foldables, when no device orientation gives the requested rotation, AXe sets the original device orientation back. On other simulators AXe sets the matching device orientation (landscape is device `landscapeRight`) and prints a warning when the foreground interface does not rotate.
- Added a one-time recovery for an unresponsive accessibility service: when a read finds no frontmost application, gets no answer, or returns an empty application element, AXe restarts the simulator's `com.apple.CoreSimulator.bridge` (`launchctl kickstart -k`), prints a warning, and retries once. A command (or a whole `batch`) restarts a simulator's bridge at most once; if the restart fails, AXe warns and keeps the original result. Set `AXE_AX_RECOVERY=never` to turn it off.
- Added `hinge` and `rotate` batch steps. They run as barriers and make later steps re-read display and accessibility state.
- Added touch delivery to the active display of foldable simulators: `tap`, `swipe`, `drag`, `slider`, `gesture`, `touch`, and batch touch steps reach the inner display of an unfolded iPhone Duo in every rotation, as well as the cover display. Coordinates are interface points of the active display as `axe screenshot` shows it; a point outside the display fails instead of being sent. Selector taps resolve against the active display's windows only, so home-screen labels no longer match twice. `gesture` presets default to the active display's size there. Touch commands fail with an explicit error only when AXe cannot determine the active display, or when the inner display is active on the legacy Indigo input transport, which cannot address it. With `AXE_DISPLAY_PROBE=never`, touches still go to the active display (IDB routes them), but AXe skips its display checks: selector taps (`--id`, `--label`, `--value`), `slider`, `gesture` presets and `describe-ui` stay unaware of the active display, so while the inner display is active they use SpringBoard's native portrait frames on the home screen and can land in the wrong place; AXe prints a one-time warning saying so.
- Added active-display output to `describe-ui` on foldable simulators: with the inner display active it reports only that display's windows, with frames in its interface points, so home-screen labels no longer appear twice, and `describe-ui --point` hit-tests interface points of the inner display in AXe instead of failing or returning the cover's backing window. Added `describe-ui --all-displays` to print the tree as the simulator reports it, without AXe's filtering and frame conversion (with upstream IDB this is already the active display's tree, with home-screen frames in native portrait points). Output with the cover active and on other simulators is unchanged; when the active display cannot be determined, `describe-ui` prints a warning and the unfiltered tree instead of failing.
- Added `axe record-video --display auto|cover|inner|<id>|<name>`. On foldable simulators, or with an explicit display, AXe records that display with `xcrun simctl io recordVideo` (H.264 at the display's native size, remuxed to MP4) and stops it with SIGINT on Ctrl+C, waiting for simctl to finish the file; `--fps`, `--quality` and `--scale` other than 1.0 fail on that path because simctl cannot honour them. Other simulators keep the existing capture path.
- Added `axe stream-video --display auto|cover|inner|<id>|<name>` to name the streamed display. The stream follows the active display, so on foldable simulators a named display streams only while it is active: the cover while folded, the inner display while unfolded. Naming the inactive display fails with an explanation.
- Added `axe remote up|down|left|right|select|menu|play-pause [--count N] [--delay ms]` for tvOS simulators, on IDB's Siri Remote events (focus moves, select and menu are keyboard usages the tvOS focus engine reads; play-pause is the consumer Play/Pause button), and a matching `remote` batch step. Other platforms are refused before anything is sent.
- Added a platform field to `axe list-simulators`: each line ends with `| Platform 'iOS|watchOS|tvOS|visionOS|unknown'` after IDB's unchanged fields. iPad simulators report `iOS`; Apple Vision Pro, which IDB reports without a product family, is recognised from its `xrOS` runtime; `unknown` means AXe recognises neither the product family nor the runtime. Scripts that parse `list-simulators` by taking the last `|`-separated field, or that expect `OS '…'` at the end of the line, must skip the new trailing field.

### Changed

- Changed AXe to build on upstream IDB v1.7.7 instead of a fork, linked statically: the release payload no longer contains `Frameworks/`, and ships the IDB simulator helper in `Resources/` instead. AXe now requires macOS 15 or later on Apple silicon; Intel Macs are no longer supported.
- Changed touch delivery to send interface points of the active display and let IDB route and rotate them. Whenever the simulator reports a usable display (an identified display on iOS 27 runtimes, or the single display of the legacy report that Xcode 27 gets from an iOS 26 runtime), IDB rotates the points itself and AXe no longer applies its own rotation for a rotated single-display simulator; only runtimes with no usable display report keep AXe's rotation mapping. The `axe touch` hid-broker protocol version is now 4, so an older broker is never reused.
- Changed `axe button apple-pay` to send two side-button presses 0.15 s apart on the DTUHID input transport, which has no Apple Pay button; with `--duration` each press holds for half of it. AXe predicts the transport from the loaded CoreSimulator version (1155.4 or later uses DTUHID), as IDB chooses it, rather than from a running `dtuhidd`, which starts on demand; if IDB still refuses the Apple Pay event, AXe sends the two side-button presses instead, in `batch` too. Indigo simulators keep the Apple Pay button event.
- Changed `axe record-video` on single-display simulators to record with IDB's H.264 encoder at a constant frame rate instead of encoding polled screenshots; `--quality` sets the encoder's quality target, and progress is printed once a second instead of as frame counts. A recording that produces no frame within 5 seconds now fails at once instead of when it is stopped.
- Changed simulator lookup to IDB's CoreSimulator service, which uses the Xcode selected with `xcode-select` and ignores `DEVELOPER_DIR`; AXe's `xcrun` calls still honour `DEVELOPER_DIR`. Development builds find IDB's accessibility helper in the checkout's `build_products/idb/bridge`; `AXE_IDB_BRIDGE_DIR` overrides the location and fails with an error when the directory does not contain the helper.
- Changed `axe batch` steps whose input is interrupted by a display change (a rotation, fold or unfold during the step): IDB stops the step instead of sending the rest of its events with stale coordinates, and the step fails with a message naming the step and the cause. Put display changes in their own `rotate` or `hinge` step.
- Changed `describe-ui` to report each element's accessibility `traits` (for example `Button`, `StaticText`, `Header`) instead of an always-empty `traits` array. IDB's accessibility backend returns them on Xcode 27.2; the former serializer emptied the hierarchy when traits were requested. Elements without traits keep an empty array.
- Changed `axe button` (and the batch `button` step) to accept the buttons of the simulator's platform: iOS keeps apple-pay, home, lock, side-button and siri; watchOS takes home (Digital Crown press), side-button, lock and siri; tvOS takes the new play-pause, volume-up and volume-down. Any other button fails before anything is sent, naming the platform and its valid buttons.
- Changed input and device commands on watchOS, tvOS and visionOS simulators to fail early with a clear message instead of an IDB error: on tvOS, touch commands (`tap`, `swipe`, `drag`, `gesture`, `touch`, `slider`, selector taps, batch touch steps) say to use `axe remote`; on visionOS every input command and `batch` fail before connecting to the HID service, because IDB v1.7.7 drives only the touch digitizer service, which visionOS does not provide; `rotate` and `hinge` say they are iOS only before contacting Device Hub. `posture` still works everywhere.
- Changed coordinate handling on watchOS, tvOS and visionOS to pass coordinates through without the iOS rotation and landscape-letterbox inference, so coordinate taps on watchOS no longer read the accessibility tree first.
- Changed accessibility recovery to restart `com.apple.CoreSimulator.bridge` in the simulator's launchd domain: `system` on watchOS (which has no `user/foreground` domain), `user/foreground` on iOS and visionOS, and both in turn on tvOS (a domain that fails or times out no longer stops the next one, and the error lists each domain's result). Selector lookups (`--id`, `--label`, `--value`) on watchOS, whose accessibility tree is only a root without children, now say so and suggest `describe-ui --point` or coordinate taps (tvOS and visionOS refuse selector taps earlier, as touch input).
- Changed `axe gesture` presets (and the batch `gesture` step) on watchOS to size themselves from the simulator's main screen instead of the 390x844 iPhone default when `--screen-width`/`--screen-height` are not given, and the scroll presets to move at most 60% of the screen along their axis (200 points on screens about 333 points or larger, as before), so the swipe stays on the watch screen.
- Changed `type`, `key`, `key-sequence` and `key-combo` (and their batch steps) to check the simulator's platform before sending anything, like the touch and button commands: visionOS is refused with the same message.
- Changed platform checks to report a mistyped or missing UDID as "No simulator with UDID … was found" instead of a platform refusal, and to describe a simulator whose platform AXe does not recognise as running "an unrecognised platform".

### Fixed

- Fixed the release smoke test failing on macOS runners that refuse unsigned frameworks: it now ad-hoc signs the extracted copy of the unsigned Homebrew archive before running it.
- Fixed one-shot touch commands (`tap`, `swipe`, `drag`, `gesture`, and the first touch of a `batch`) on Xcode 27 simulators silently losing the touch. The simulator's `dtuhidd` needs about 0.2 s to set up input services for a new connection and AXe disconnected before that; IDB now confirms the session is live before the first event and waits for each send to be acknowledged. Previously only `--tap-style physical` was reliable.
- Fixed `axe screenshot` on foldable simulators capturing the inner display even while the cover display was active, which produced a black image when folded. `record-video` had the same problem (see Added).
- Fixed touch commands (`tap`, `swipe`, `drag`, `slider`, `gesture`, `touch`, and batch touch steps) reporting success without delivering input on a foldable simulator whose inner display is active; they are now delivered to the active display (see Added). Coordinates on the inner display take its orientation and size from the simulator's display state instead of the cover screen.
- Fixed AXe errors that are wrapped in another message, such as `axe batch` step failures, showing a generic system message instead of the underlying AXe error. Batch step argument errors now show the parser's message instead of "The operation couldn't be completed".

### Removed

- Removed the testmanagerd restart that AXe ran after an accessibility channel disconnect; IDB's accessibility backend does not use testmanagerd.

## [v1.8.0] - 2026-07-20

### Added

- Added Xcode 27 and iOS 27 simulator automation through Device Hub without requiring Simulator.app, while retaining Xcode 26 support ([#60](https://github.com/cameroncooke/AXe/pull/60) by [@jkaunert](https://github.com/jkaunert)). See [Xcode compatibility](README.md#xcode-compatibility).

### Changed

- Strengthened release supply-chain integrity with immutable, verified IDB sources and stricter validation of release inputs and signing identities.

### Fixed

- Fixed BGRA video streams ignoring the requested `--fps` value and running at an uncapped frame rate.
- Fixed release archives failing strict Gatekeeper verification because of embedded filesystem metadata.
- Fixed commands exposing low-level simulator errors instead of actionable failure messages.

Various other internal improvements to stability, performance, and code quality.

## [v1.7.1] - 2026-06-02

### Added

- Added AxePlayground alert, sheet, context menu, modal navigation, and long-scroll fixtures for UI automation regression coverage.

## [v1.7.0] - 2026-05-11

### Added

- Added `axe slider --id/--label --value 0...100` for selector-based slider setting with orientation-aware HID dragging and AXValue tolerance verification/failure reporting.
- Added `axe drag --start-x/--start-y --end-x/--end-y` for raw point-to-point low-level HID drag validation using explicit touch move events.

### Changed

- Changed `axe slider` to use the shared composite low-level HID drag path with AXValue tolerance verification instead of retrying with correction gestures.

### Fixed

- Fixed `describe-ui` and selector-based `tap --label` exposing and activating real SwiftUI `TabView` tab items, navigation search fields, toolbar segmented picker items, and generated navigation back buttons from the CoreSimulator accessibility bridge. Also fixed selector decoding when the accessibility tree contains numeric `AXValue` fields such as sliders.
- Fixed `tap`, `touch`, `swipe`, and matching batch steps dispatching logical UI coordinates directly to FBSimulatorHIDEvent without landscape rotation or letterbox correction, causing interactions to land in the wrong location in rotated landscape simulators and portrait-hardware landscape-only apps. AXe now detects the simulator UI orientation automatically instead of requiring callers to pass landscape flags ([#5](https://github.com/cameroncooke/AXe/issues/5) by [@Nitewriter](https://github.com/Nitewriter))
- Fixed selector-based `tap` and batch tap steps so UIKit `UISwitch` and SwiftUI `Toggle` controls can be activated reliably, including when a matched row or label contains a single switch/toggle control. Added `--tap-style` so switch/toggle taps can use physical touch automatically while normal taps keep the simulator `tapAt` path by default ([#46](https://github.com/cameroncooke/AXe/pull/46)).
- Fixed element comparison in `AccessibilityTargetResolver` to prevent distinct elements with the same type and frame but lacking labels/values from being incorrectly identified as identical during ancestor tree traversal.

## [v1.6.0] - 2026-04-05

### Added

- Added `--value` targeting for `tap`, allowing elements to be matched by their accessibility value in addition to `--id` and `--label`. Added `--element-type` filtering to narrow matches by element type (e.g., button, text field) ([#40](https://github.com/cameroncooke/AXe/pull/40) by [@andresdefi](https://github.com/andresdefi)).
- Added `--wait-timeout` and `--poll-interval` options to `tap` for waiting until a matching element appears before tapping ([#40](https://github.com/cameroncooke/AXe/pull/40) by [@andresdefi](https://github.com/andresdefi)).

### Fixed

- Fixed `describe-ui` to expose and implement the documented `--point` option in command help and runtime behavior ([#38](https://github.com/cameroncooke/AXe/issues/38))

## [v1.5.0] - 2026-03-04

### Added

- Added `batch` command for executing ordered multi-step interaction workflows in a single invocation, with sequential execution that supports multi-screen flows, built-in `sleep` delays, accessibility caching, and configurable text submission strategies ([#25](https://github.com/cameroncooke/AXe/pull/25)). See [BATCHING.md](BATCHING.md).
- Added `axe init` command to install, uninstall, or print the AXe skill for AI clients (`claude`, `agents`) or a custom destination ([#25](https://github.com/cameroncooke/AXe/pull/25)).

### Fixed

- Fixed Homebrew installation on Intel Macs by producing architecture-specific release artifacts ([#27](https://github.com/cameroncooke/AXe/pull/27), [#21](https://github.com/cameroncooke/AXe/issues/21))
- Fixed `tap --label` resolving ambiguous matches by preferring actionable elements over read-only ones ([#28](https://github.com/cameroncooke/AXe/pull/28))

## [v1.4.0] - 2026-02-08

### Added

- AxePlayground Touch Control now shows long-press count and last long-press coordinates, making gesture automation easier to validate.

### Fixed

- Improved long-press reliability for `axe touch`: `--down --up --delay` now consistently behaves like a real press-and-hold gesture.

## [v1.3.0] - 2026-01-28

- Add `key-combo` command for atomic modifier+key presses (e.g., Cmd+A, Cmd+Shift+Z) Thanks to @jpsim for the contribution!

## [v1.2.0] - 2025-12-19

-Add support for screenshot capture to PNG
-Add tap by label or accessibility id in addition to existing x/y coordinates
-Fix FBProcess duplication warnings

Special thanks to @aliceisjustplaying and @onevcat for their execellent contributions!

## [v1.1.1] - 2025-09-22

-Pin IDB version to address access control issues on new versions


## [v1.1.0] - 2025-09-21

- Add support for streaming and video capture (thanks to @pepicrft for the contribution!)


## [v1.0.0] - 2025-06-01

- Initial release of AXe
- Complete CLI tool for iOS Simulator automation
- Support for tap, swipe, type, key, touch, button, and gesture commands
- Built on Meta's idb frameworks with Swift async/await
- Comprehensive test suite with AxePlaygroundApp
- Gesture presets and timing controls
- Accessibility API integration

## [v0.1.1] - 2025-09-21
- README updates

## [v0.1.0] - 2025-05-27

- Initial release of AXe
