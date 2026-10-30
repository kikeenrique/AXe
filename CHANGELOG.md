# Changelog

All notable changes to the AXe iOS testing framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added `axe screenshot --display auto|cover|inner|<id>|<name>` to choose the captured display. `auto` (default) captures the active display; on foldable simulators (iPhone Duo) the display state is read with `xcrun devicectl`, which non-foldable simulators never run. Set `AXE_DISPLAY_PROBE=auto|always|never` to override when display detection runs.
- Added `axe hinge set|open|close|half|sweep|get` for foldable simulators (iPhone Duo, Xcode 27.1 or later). Every change sweeps from the current angle (never an instant jump), confirms the angle the simulator reports, and waits for the cover or inner display to become active. Based on [hinge](https://github.com/artemnovichkov/hinge) by Artem Novichkov and [duoctl](https://github.com/skarol/duoctl) by Karolina Samorek; AXe builds a small in-simulator helper on first use and caches it under `~/Library/Caches/AXe/sim-helper`.
- Added `axe posture` to print the hinge angle, the active display, and each display's rotation, interface orientation and size in points, as text or `--json`. Works on any simulator; the hinge angle is `null` without a hinge.
- Added `axe rotate portrait|landscape|portrait-upside-down|landscape-flipped` to rotate the interface of the active display, verified by the display rotation devicectl reports. Other simulators use `devicectl device orientation set` and print a warning when the foreground interface does not rotate.
- Added `hinge` and `rotate` batch steps. They run as barriers and make later steps re-read display and accessibility state.
- Added touch delivery to the active display of foldable simulators: `tap`, `swipe`, `drag`, `slider`, `gesture`, `touch`, and batch touch steps reach the inner display of an unfolded iPhone Duo in every rotation, as well as the cover display. Coordinates are interface points of the active display as `axe screenshot` shows it; a point outside the display fails instead of being sent. Selector taps resolve against the active display's windows only, so home-screen labels no longer match twice. `gesture` presets default to the active display's size there. Touch commands fail with an explicit error only when AXe cannot determine the active display, or when the inner display is active on the legacy Indigo input transport, which cannot address it. With `AXE_DISPLAY_PROBE=never`, touches go to the cover display and AXe prints a warning on foldable simulators.
- Added active-display output to `describe-ui` on foldable simulators: with the inner display active it reports only that display's windows, with frames in its interface points, so home-screen labels no longer appear twice, and `describe-ui --point` hit-tests interface points of the inner display in AXe instead of failing or returning the cover's backing window. Added `describe-ui --all-displays` to print the simulator's unfiltered tree. Output with the cover active and on other simulators is unchanged; when the active display cannot be determined, `describe-ui` prints a warning and the unfiltered tree instead of failing.
- Added `axe record-video --display auto|cover|inner|<id>|<name>`. On foldable simulators, or with an explicit display, AXe records that display with `xcrun simctl io recordVideo` (H.264 at the display's native size, remuxed to MP4) and stops it with SIGINT on Ctrl+C, waiting for simctl to finish the file; `--fps`, `--quality` and `--scale` other than 1.0 fail on that path because simctl cannot honour them. Other simulators keep the existing capture path.
- Added `axe stream-video --display auto|inner|<id>|<name>` to name the streamed display. The stream reads the inner display's framebuffer, so only the inner display can be streamed on foldable simulators.

### Changed

- Changed `axe stream-video` on foldable simulators to fail with an explanation unless `--display inner` (or its ID or name) is passed. Previously it streamed the inner display's framebuffer whatever the fold state, which is black while folded. Other simulators are unchanged.

### Fixed

- Fixed one-shot touch commands (`tap`, `swipe`, `drag`, `gesture`, and the first touch of a `batch`) on Xcode 27 simulators silently losing the touch. The simulator's `dtuhidd` needs about 0.2 s to set up input services for a new connection and AXe disconnected before that; the HID transport now waits for the session before the first event (`FB_DTUHID_READINESS_MS`, default 400). Previously only `--tap-style physical` was reliable. The fix lives in the pinned IDB fork, which now also accepts a target display for touches.
- Fixed `axe screenshot` on foldable simulators capturing the inner display even while the cover display was active, which produced a black image when folded. `record-video` had the same problem (see Added).
- Fixed touch commands (`tap`, `swipe`, `drag`, `slider`, `gesture`, `touch`, and batch touch steps) reporting success without delivering input on a foldable simulator whose inner display is active; they are now delivered to the active display (see Added). Coordinates on the inner display take its orientation and size from devicectl instead of the cover screen. The `axe touch` hid-broker uses a new protocol version, so a broker started by an earlier AXe version is never reused.
- Fixed AXe errors that are wrapped in another message, such as `axe batch` step failures, showing a generic system message instead of the underlying AXe error. Batch step argument errors now show the parser's message instead of "The operation couldn't be completed".

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
