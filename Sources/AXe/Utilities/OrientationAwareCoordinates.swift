import Darwin
import Foundation
import AXeCore
import FBControlCore
import FBSimulatorControl
import FBSimulatorServices

// MARK: - Simulator Orientation

/// Logical UI orientation of a simulator as reported by its accessibility tree.
///
/// Matches UIInterfaceOrientation semantics:
///   - `portrait`            — home button at the bottom (default)
///   - `portraitUpsideDown`  — home button at the top (180°)
///   - `landscape`           — home button to the right (90° CW from portrait)
///   - `landscapeFlipped`    — home button to the left (90° CCW from portrait)
enum SimulatorOrientation: String, CaseIterable {
    case portrait
    case portraitUpsideDown
    case landscape
    case landscapeFlipped

    /// True when the logical screen width is wider than tall.
    var isLandscape: Bool {
        coreOrientation.isLandscape
    }

    var coreOrientation: OrientationCoordinateMath.Orientation {
        switch self {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscape:
            return .landscape
        case .landscapeFlipped:
            return .landscapeFlipped
        }
    }
}

// MARK: - Coordinate Mapping

/// Describes how logical coordinates from the accessibility tree map to the physical
/// portrait coordinate space that SimulatorHIDEvent expects.
///
/// The AX application frame alone cannot distinguish two landscape cases:
///   - **Rotation:**  hardware is in landscape (device rotated). Rotation math applies.
///   - **Letterbox:** hardware is portrait, but the app declares landscape-only
///     orientations. iOS scales + centers the landscape UI inside the portrait
///     viewport. Scale + offset math applies.
///
/// Detection: read the active display's rotation from IDB (or the device orientation on
/// runtimes without display reports), then fall back to screenshot pixel aspect ratio to
/// distinguish portrait-hardware letterboxing from a rotated simulator.
enum CoordinateMapping {
    /// Portrait device, portrait app — pass coordinates through unchanged.
    case passthrough

    /// Hardware is rotated. Apply rotation math.
    ///
    /// `portraitSize` = `(width: shortSide, height: longSide)` in logical points.
    case rotation(SimulatorOrientation, portraitSize: (width: Double, height: Double))

    /// Hardware is portrait, app is landscape-only. Apply letterbox scale + offset.
    ///
    /// Physical point = `(offsetX + lx * scale, offsetY + ly * scale)`.
    case letterbox(scale: Double, offsetX: Double, offsetY: Double)

    /// The active display of a foldable is not the main display. Interface points (including
    /// selector points, which come from the interface-space panel tree) are sent unchanged, because
    /// IDB routes them to the active display and rotates them; points outside the panel are refused.
    case display(TouchTarget)
}

// MARK: - IDB Touch Routing

/// Whether IDB routes touches to a display whose geometry it knows, and so clamps and unrotates
/// interface points itself.
///
/// Mirrors upstream `SimulatorHIDOperation.route`: a touch is bound to a display (and rotated by
/// that display's interface rotation) when `resolveDisplay()` yields a target, which is exactly
/// when `SimulatorDisplayConfiguration.activeGeometry()` succeeds: an identified active display
/// (iOS 27 reports) or the sole integrated display of a legacy report (Xcode 27.x driving an iOS 26
/// runtime, which sends no display identity but does send the geometry and rotation). A failed
/// read, unknown activity, several legacy displays, or no/several active displays fall back to
/// the main display with raw points; a transitioning layout makes IDB refuse the touch.
/// `activeDisplay()` is not the right test: it throws for the legacy report that IDB still routes.
enum IDBTouchRouting: Equatable {
    /// IDB binds the touch to the active display and unrotates interface points: AXe passes them through.
    case activeDisplay
    /// IDB sends the points raw to the main display: AXe applies its own rotation.
    case rawPoints(reason: String)

    init(configuration: SimulatorDisplayConfiguration) {
        do {
            _ = try configuration.activeGeometry()
            self = .activeDisplay
        } catch {
            self = .rawPoints(reason: error.localizedDescription)
        }
    }
}

// MARK: - Orientation-Aware Coordinate Translation

/// Translates logical UI coordinates (as reported by the accessibility tree and
/// consumed by `axe tap`, `axe touch`, and `axe swipe`) into the physical portrait
/// coordinate space that SimulatorHIDEvent expects.
///
/// ## Root cause
/// The iOS Simulator's HID layer always operates in physical portrait space.
/// The accessibility tree, however, reports element positions in the *logical*
/// orientation the app currently presents.  When the device is rotated, logical
/// coordinates must be mapped back to physical portrait before dispatching HID
/// events, otherwise taps land in the wrong location.
///
/// ## Two landscape cases
/// Both a rotated device and a portrait device running a landscape-only app produce
/// a landscape-shaped AX application frame. AXe first asks IDB for the active display's
/// interface rotation so it can distinguish landscape left from landscape right
/// automatically. If the orientation is unavailable, screenshot dimensions are used only
/// to distinguish rotated hardware from a portrait device running a letterboxed
/// landscape-only app. If the screenshot confirms rotated hardware but the orientation is
/// unavailable, AXe fails clearly instead of guessing landscape direction.
///
/// ## Portrait dimensions
/// The short side of the device in points is the portrait width; the long side
/// is the portrait height.  These are derived from the application frame: in
/// portrait they are `frame.width` and `frame.height`; in landscape they are
/// swapped.
@MainActor
struct OrientationAwareCoordinates {

    // MARK: - Coordinate Mapping Detection

    /// Determines which coordinate mapping to apply for the given simulator.
    ///
    /// Detection flow:
    /// 0. On a foldable whose active display is not the main one, use the `TouchTarget` from
    ///    the display state's orientation and size (no AX fetch, no orientation or screenshot
    ///    probe). Fail when the active display of a foldable cannot be determined.
    /// 1. Fetch AX application frame.
    /// 2. If an explicit override was supplied → rotation case.
    /// 3. Otherwise read the interface orientation (`interfaceOrientation(simulatorUDID:logger:)`).
    /// 4. If the orientation is unavailable and the AX frame is portrait-shaped → passthrough.
    /// 5. If unavailable and landscape-shaped, probe screenshot dimensions (of the active display on foldables).
    ///    - Screenshot portrait-shaped (taller than wide) → letterbox case.
    ///    - Screenshot landscape-shaped (wider than tall) → rotated device case.
    ///
    /// - Parameters:
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: Forces a specific rotated-device `SimulatorOrientation`.
    ///     Intended for internal tests or future explicit callers; normal CLI commands
    ///     rely on automatic orientation detection.
    ///   - logger: AXe logger instance.
    /// - Returns: The `CoordinateMapping` that applies to the current simulator state.
    static func detectMapping(
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> CoordinateMapping {
        if let mapping = platformMapping(for: SimulatorSession.platform(udid: simulatorUDID, logger: logger), logger: logger) {
            return mapping
        }
        if let target = try await TouchTarget.nonMainTarget(forSimulatorUDID: simulatorUDID, logger: logger) {
            return displayMapping(for: target, logger: logger)
        }

        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(
            for: simulatorUDID,
            logger: logger
        )

        return try await detectMapping(
            from: roots,
            simulatorUDID: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )
    }

    static func detectMapping(
        from roots: [AccessibilityElement],
        simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> CoordinateMapping {
        if let mapping = platformMapping(for: SimulatorSession.platform(udid: simulatorUDID, logger: logger), logger: logger) {
            return mapping
        }
        // A non-main active display of a foldable maps through its TouchTarget: the AX application
        // frame is the cover's size, so it does not describe the inner panel. Non-foldables get nil
        // without a display read, and a failed simulator lookup is treated as nil.
        let displayState = try await SimulatorDisplays.state(forSimulatorUDID: simulatorUDID, logger: logger)
        if let target = try TouchTarget.resolve(state: displayState), !target.isMain {
            return displayMapping(for: target, logger: logger)
        }

        guard let appFrame = applicationFrame(from: roots) else {
            throw CLIError(errorDescription: "Unable to determine coordinate mapping because the accessibility application frame is unavailable.")
        }

        if let orientationOverride {
            logger.info().log("Using explicit orientation override: \(orientationOverride.rawValue)")
            guard let portraitSize = portraitDimensions(from: roots, orientation: orientationOverride) else {
                throw CLIError(errorDescription: "Unable to determine coordinate mapping because portrait dimensions are unavailable.")
            }
            guard orientationOverride != .portrait else {
                return .rotation(orientationOverride, portraitSize: portraitSize)
            }
            return rotatedMapping(
                orientationOverride,
                portraitSize: portraitSize,
                routing: await idbTouchRouting(simulatorUDID: simulatorUDID, logger: logger),
                logger: logger
            )
        }

        let probeDisplayID = displayState.flatMap { $0.isMultiDisplay ? $0.activeDisplay?.displayId : nil }

        // Prefer the simulator's reported interface rotation when available; this
        // distinguishes landscape-left from landscape-right and catches upside-down portrait.
        let simulatorOrientation = await interfaceOrientation(simulatorUDID: simulatorUDID, logger: logger)

        if let simulatorOrientation {
            logger.info().log("Detected simulator UI orientation: \(simulatorOrientation.rawValue)")
            guard let portraitSize = portraitDimensions(from: roots, orientation: simulatorOrientation) else {
                throw CLIError(errorDescription: "Unable to determine coordinate mapping because portrait dimensions are unavailable.")
            }

            switch simulatorOrientation {
            case .portrait:
                guard appFrame.width > appFrame.height else {
                    return .passthrough
                }
                logger.info().log(
                    "Simulator reports portrait but AX frame \(Int(appFrame.width))×\(Int(appFrame.height)) is landscape; probing for letterbox mapping"
                )
            case .portraitUpsideDown, .landscape, .landscapeFlipped:
                return rotatedMapping(
                    simulatorOrientation,
                    portraitSize: portraitSize,
                    routing: await idbTouchRouting(simulatorUDID: simulatorUDID, logger: logger),
                    logger: logger
                )
            }
        }

        guard appFrame.width > appFrame.height else {
            logger.info().log(
                "AX frame \(Int(appFrame.width))×\(Int(appFrame.height)) is portrait; passthrough"
            )
            return .passthrough
        }

        // Fall back to screenshot aspect ratio to distinguish rotated hardware from a
        // portrait device running a landscape-only app.
        logger.info().log(
            "AX frame \(Int(appFrame.width))×\(Int(appFrame.height)) is landscape; probing screenshot dimensions"
        )

        let screenshotDims = await screenshotPixelDimensions(
            for: simulatorUDID,
            displayID: probeDisplayID,
            logger: logger
        )

        if let dims = screenshotDims, dims.height > dims.width {
            // Screenshot is portrait-shaped despite a landscape AX frame →
            // hardware is portrait, app is landscape-only: letterbox case.
            logger.info().log(
                "Screenshot \(dims.width)×\(dims.height)px is portrait-shaped; using letterbox mapping"
            )

            // Physical viewport in points: short side = portrait width, long side = portrait height.
            // Derived from the landscape AX frame by swapping axes (same as portraitDimensions).
            let physW = appFrame.height  // portrait width  = landscape logical height
            let physH = appFrame.width   // portrait height = landscape logical width
            let logW  = appFrame.width   // logical landscape width
            let logH  = appFrame.height  // logical landscape height

            // Uniform scale to fit logical content into physical viewport.
            let scale = min(physW / logW, physH / logH)
            let offsetX = (physW - logW * scale) / 2
            let offsetY = (physH - logH * scale) / 2

            logger.info().log(
                String(format: "Letterbox: scale=%.4f offsetX=%.1f offsetY=%.1f", scale, offsetX, offsetY)
            )
            return .letterbox(scale: scale, offsetX: offsetX, offsetY: offsetY)
        }

        guard let screenshotDims else {
            throw CLIError(errorDescription: "Unable to determine coordinate mapping because screenshot probing failed for a landscape accessibility frame.")
        }

        // Screenshot is landscape-shaped — hardware is rotated.
        logger.info().log(
            "Screenshot \(screenshotDims.width)×\(screenshotDims.height)px is landscape-shaped; using rotation mapping"
        )

        if await idbTouchRouting(simulatorUDID: simulatorUDID, logger: logger) == .activeDisplay {
            logger.info().log("IDB reads the active display's rotation and rotates touches itself; passing interface points through")
            return .passthrough
        }

        throw CLIError(errorDescription: "Unable to determine rotated simulator orientation. AXe can read landscape coordinates only when the simulator reports the current interface or device orientation; the screenshot confirms the simulator is rotated, but neither was available.")
    }

    /// The mapping fixed by the platform, before any accessibility, orientation or screenshot probe:
    /// passthrough (rotation 0, no letterbox) on watchOS, tvOS and visionOS, whose simulators are
    /// not portrait-native phones. A visionOS window space is landscape-shaped and a watch face is
    /// nearly square, so the iOS inference would take a landscape or letterbox branch for them.
    /// `nil` on iOS (and unknown platforms), where detection runs.
    static func platformMapping(for platform: SimulatorPlatform, logger: AxeLogger? = nil) -> CoordinateMapping? {
        guard !platform.usesPhoneCoordinateModel else { return nil }
        logger?.info().log("\(platform.displayName) simulator: passing coordinates through (rotation 0, no letterbox)")
        return .passthrough
    }

    /// The mapping for a rotated single-display simulator: AXe's own rotation only when IDB sends
    /// the points raw. When IDB routes to the active display it unrotates interface points itself,
    /// and rotating them here as well would land the touch in the wrong place.
    static func rotatedMapping(
        _ orientation: SimulatorOrientation,
        portraitSize: (width: Double, height: Double),
        routing: IDBTouchRouting,
        logger: AxeLogger? = nil
    ) -> CoordinateMapping {
        switch routing {
        case .activeDisplay:
            logger?.info().log("IDB reads the active display's rotation and rotates touches itself; passing interface points through")
            return .passthrough
        case .rawPoints:
            return .rotation(orientation, portraitSize: portraitSize)
        }
    }

    /// The interface orientation of the active display: the rotation of IDB's display
    /// configuration, or on runtimes that report no usable display, the device orientation IDB
    /// reads (device `landscapeRight` shows `landscape`). `nil` when neither is available.
    static func interfaceOrientation(simulatorUDID: String, logger: AxeLogger) async -> SimulatorOrientation? {
        guard let simulator = (try? SimulatorSession.simulator(udid: simulatorUDID, logger: logger)) ?? nil else {
            logger.info().log("Orientation probe: simulator \(simulatorUDID) not found")
            return nil
        }
        do {
            let rotation = try await simulator.displays.configuration().activeGeometry().rotation
            logger.info().log("Orientation probe: active display rotation \(rotation.rawValue)")
            return SimulatorDisplay.Rotation(rawValue: rotation.rawValue)?.simulatorOrientation
        } catch {
            logger.info().log("Orientation probe: no display rotation (\(error.localizedDescription)); reading the device orientation")
        }
        do {
            switch try await simulator.orientation.current() {
            case .portrait:
                return .portrait
            case .portraitUpsideDown:
                return .portraitUpsideDown
            case .landscapeRight:
                return .landscape
            case .landscapeLeft:
                return .landscapeFlipped
            default:
                return nil
            }
        } catch {
            logger.info().log("Orientation probe failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// How IDB will treat the touches AXe sends to this simulator (see `IDBTouchRouting`).
    static func idbTouchRouting(simulatorUDID: String, logger: AxeLogger) async -> IDBTouchRouting {
        do {
            guard let simulator = try SimulatorSession.simulator(udid: simulatorUDID, logger: logger) else {
                return .rawPoints(reason: "simulator \(simulatorUDID) not found")
            }
            let routing = IDBTouchRouting(configuration: try await simulator.displays.configuration())
            if case .rawPoints(let reason) = routing {
                logger.info().log("IDB has no active display to route to (\(reason)); AXe rotates touches")
            }
            return routing
        } catch {
            logger.info().log("IDB display configuration unavailable (\(error.localizedDescription)); AXe rotates touches")
            return .rawPoints(reason: error.localizedDescription)
        }
    }

    private static func displayMapping(for target: TouchTarget, logger: AxeLogger) -> CoordinateMapping {
        let size = target.nativePointSize
        logger.info().log(
            "Active display \(target.displayID) is not the main display; using its \(target.rotation.rawValue) over \(size.width)x\(size.height) pt"
        )
        return .display(target)
    }

    // MARK: - Screenshot Dimension Probe

    /// Reads the pixel dimensions of the current simulator screenshot from a
    /// temporary PNG generated by `xcrun simctl io <udid> screenshot`.
    ///
    /// Only the PNG header is read from the temporary file, which is removed
    /// before this function returns.
    ///
    /// - Parameter displayID: Display to capture on multi-display simulators. simctl refuses to
    ///   choose between several displays without it.
    /// - Returns: `nil` if the process fails or the output is not a valid PNG.
    static func screenshotPixelDimensions(
        for simulatorUDID: String,
        displayID: Int? = nil,
        logger: AxeLogger
    ) async -> (width: Int, height: Int)? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-screenshot-probe-\(UUID().uuidString)")
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var arguments = ["simctl", "io", simulatorUDID, "screenshot", "--type", "png"]
        if let displayID {
            arguments.append("--display=\(displayID)")
        }
        arguments.append(tempURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.info().log("Screenshot probe: could not launch xcrun simctl: \(error)")
            return nil
        }

        guard await waitForProcessExit(process, timeout: 3.0, logger: logger), process.terminationStatus == 0 else {
            logger.info().log("Screenshot probe: simctl screenshot failed or timed out")
            return nil
        }

        let headerData: Data
        do {
            let fileHandle = try FileHandle(forReadingFrom: tempURL)
            defer { try? fileHandle.close() }
            headerData = try fileHandle.read(upToCount: 24) ?? Data()
        } catch {
            logger.info().log("Screenshot probe: could not read temp PNG: \(error)")
            return nil
        }

        guard headerData.count >= 24 else {
            logger.info().log("Screenshot probe: PNG header too short (\(headerData.count) bytes)")
            return nil
        }

        // Verify PNG signature: 8 bytes \x89PNG\r\n\x1a\n
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard headerData.prefix(8).elementsEqual(pngSignature) else {
            logger.info().log("Screenshot probe: output is not a valid PNG")
            return nil
        }

        // IHDR width and height at bytes 16-19 and 20-23 (big-endian uint32).
        let widthBytes  = headerData[16..<20]
        let heightBytes = headerData[20..<24]

        let width  = widthBytes.reduce(0)  { Int($0) << 8 | Int($1) }
        let height = heightBytes.reduce(0) { Int($0) << 8 | Int($1) }

        logger.info().log("Screenshot probe: \(width)×\(height)px")
        return (width: width, height: height)
    }

    private static func waitForProcessExit(
        _ process: Process,
        timeout: TimeInterval,
        logger: AxeLogger
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard process.isRunning else {
            process.waitUntilExit()
            return true
        }

        logger.info().log("Screenshot probe: timed out waiting for simctl screenshot")
        process.terminate()

        let terminateDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < terminateDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        if process.isRunning {
            logger.info().log("Screenshot probe: force-killing unresponsive simctl screenshot process")
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return false
    }

    // MARK: - Coordinate Translation

    /// Translates a logical point (as reported by the accessibility tree) to the
    /// physical portrait point expected by SimulatorHIDEvent using rotation math.
    ///
    /// - Parameters:
    ///   - point: Logical (x, y) in the current UI orientation.
    ///   - orientation: The current logical orientation of the simulator.
    ///   - portraitSize: The device's portrait dimensions `(width: shortSide, height: longSide)`.
    /// - Returns: Physical (x, y) in portrait space.
    static func translateToPhysical(
        point: (x: Double, y: Double),
        orientation: SimulatorOrientation,
        portraitSize: (width: Double, height: Double)
    ) -> (x: Double, y: Double) {
        OrientationCoordinateMath.translateToPhysical(
            x: point.x,
            y: point.y,
            orientation: orientation.coreOrientation,
            portraitWidth: portraitSize.width,
            portraitHeight: portraitSize.height
        )
    }

    /// Translates a logical point to a physical point using letterbox scale + offset math.
    ///
    /// iOS places a landscape-only app inside the portrait viewport by scaling it
    /// uniformly and centering it. The physical point is:
    ///
    ///   `px = offsetX + lx * scale`
    ///   `py = offsetY + ly * scale`
    ///
    /// - Parameters:
    ///   - point:   Logical (x, y) as reported by the AX tree.
    ///   - scale:   Uniform scale factor (`min(physW / logW, physH / logH)`).
    ///   - offsetX: Horizontal letterbox offset in points (`(physW - logW * scale) / 2`).
    ///   - offsetY: Vertical letterbox offset in points (`(physH - logH * scale) / 2`).
    /// - Returns: Physical (x, y) in the portrait hardware viewport.
    static func letterboxToPhysical(
        point: (x: Double, y: Double),
        scale: Double,
        offsetX: Double,
        offsetY: Double
    ) -> (x: Double, y: Double) {
        OrientationCoordinateMath.letterboxToPhysical(
            x: point.x,
            y: point.y,
            scale: scale,
            offsetX: offsetX,
            offsetY: offsetY
        )
    }

    /// Derives the device's portrait dimensions from the accessibility tree.
    ///
    /// In portrait, the application frame is already in portrait coordinates.
    /// In landscape, the width and height are swapped compared to portrait.
    ///
    /// - Parameters:
    ///   - roots: Root accessibility elements from `AccessibilityFetcher`.
    ///   - orientation: The current logical orientation.
    /// - Returns: Portrait `(width, height)`, or `nil` if the application frame is unavailable.
    static func portraitDimensions(
        from roots: [AccessibilityElement],
        orientation: SimulatorOrientation
    ) -> (width: Double, height: Double)? {
        guard let frame = applicationFrame(from: roots) else { return nil }

        if orientation.isLandscape {
            // In landscape: logical width = portrait height, logical height = portrait width
            return (width: frame.height, height: frame.width)
        }
        return (width: frame.width, height: frame.height)
    }

    // MARK: - Full Pipeline

    /// Detects the appropriate coordinate mapping and translates a single logical
    /// point to the physical portrait point expected by SimulatorHIDEvent.
    ///
    /// This is the single entry point used by `Tap`, `Touch`, and `Swipe`.
    ///
    /// Handles three cases automatically:
    /// - Portrait device, portrait app → passthrough.
    /// - Portrait device, landscape-only app → letterbox scale + offset.
    /// - Rotated hardware → rotation math.
    ///
    /// - Parameters:
    ///   - point: Logical (x, y) as supplied by the caller.
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: Optional explicit rotated-device orientation. Pass
    ///     `.landscapeFlipped` when the device is rotated counter-clockwise. Leave nil for
    ///     automatic letterbox detection in portrait-hardware landscape-only apps.
    ///   - logger: AXe logger instance.
    /// - Returns: Physical (x, y) ready for SimulatorHIDEvent.
    static func translate(
        point: (x: Double, y: Double),
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> (x: Double, y: Double) {
        let mapping = try await detectMapping(
            for: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )

        return try applyMapping(mapping, to: point, logger: logger)
    }

    static func translate(
        point: (x: Double, y: Double),
        roots: [AccessibilityElement],
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> (x: Double, y: Double) {
        let mapping = try await detectMapping(
            from: roots,
            simulatorUDID: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )

        return try applyMapping(mapping, to: point, logger: logger)
    }

    /// Translates multiple logical points using a single detection round-trip.
    ///
    /// Prefer this over calling `translate(point:for:orientationOverride:logger:)` in a loop when
    /// translating several points for the same simulator state (e.g. swipe start and end).
    ///
    /// - Parameters:
    ///   - points: Logical (x, y) pairs in the current UI orientation.
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: Optional explicit orientation for the rotated device case.
    ///   - logger: AXe logger instance.
    /// - Returns: Physical (x, y) pairs ready for SimulatorHIDEvent, in the same order as input.
    static func translateBatch(
        points: [(x: Double, y: Double)],
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> [(x: Double, y: Double)] {
        let mapping = try await detectMapping(
            for: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )

        return try points.map { try applyMapping(mapping, to: $0, logger: logger) }
    }

    static func translateBatch(
        points: [(x: Double, y: Double)],
        roots: [AccessibilityElement],
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> [(x: Double, y: Double)] {
        let mapping = try await detectMapping(
            from: roots,
            simulatorUDID: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )

        return try points.map { try applyMapping(mapping, to: $0, logger: logger) }
    }

    // MARK: - Private Helpers

    /// Applies a `CoordinateMapping` to a single logical point, logging the translation.
    ///
    /// - Throws: on a non-main display of a foldable, when the point lies outside the panel.
    static func applyMapping(
        _ mapping: CoordinateMapping,
        to point: (x: Double, y: Double),
        logger: AxeLogger
    ) throws -> (x: Double, y: Double) {
        let physical: (x: Double, y: Double)

        switch mapping {
        case .passthrough:
            return point

        case .display(let target):
            // IDB rotates interface points to the active panel; AXe only refuses points outside it.
            physical = try target.checkedInterfacePoint(point)
            logger.info().log(
                String(format: "Interface (%.1f, %.1f) is inside display %d; IDB routes and rotates it",
                       point.x, point.y, target.displayID)
            )

        case .rotation(let orientation, let portraitSize):
            physical = translateToPhysical(point: point, orientation: orientation, portraitSize: portraitSize)
            logger.info().log(
                "Translated logical (\(Int(point.x)), \(Int(point.y))) → physical (\(Int(physical.x)), \(Int(physical.y))) [rotation: \(orientation.rawValue)]"
            )

        case .letterbox(let scale, let offsetX, let offsetY):
            physical = letterboxToPhysical(point: point, scale: scale, offsetX: offsetX, offsetY: offsetY)
            logger.info().log(
                String(format: "Translated logical (%d, %d) → physical (%.1f, %.1f) [letterbox: scale=%.4f offsetX=%.1f offsetY=%.1f]",
                       Int(point.x), Int(point.y), physical.x, physical.y, scale, offsetX, offsetY)
            )
        }

        return physical
    }

    private static func applicationFrame(
        from roots: [AccessibilityElement]
    ) -> AccessibilityElement.Frame? {
        roots.first { $0.type == "Application" }?.frame
            ?? roots.first?.frame
    }

    // MARK: - Orientation Detection (legacy — preserved for callers that need it directly)

    /// Determines the current logical orientation by inspecting the accessibility tree.
    ///
    /// Prefer `detectMapping(for:orientationOverride:logger:)` for full tap/touch/swipe
    /// coordinate translation. This method only reads the AX frame and cannot distinguish
    /// a rotated device from a letterboxed landscape-only app.
    ///
    /// - Parameters:
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: When non-nil, skip detection and use this value.
    ///   - logger: AXe logger instance.
    /// - Returns: The detected (or overridden) orientation.
    static func detectOrientation(
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> SimulatorOrientation {
        if let override = orientationOverride {
            logger.info().log("Using explicit orientation override: \(override.rawValue)")
            return override
        }

        if platformMapping(for: SimulatorSession.platform(udid: simulatorUDID, logger: logger)) != nil {
            return .portrait
        }

        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(
            for: simulatorUDID,
            logger: logger
        )

        guard let appFrame = applicationFrame(from: roots) else {
            logger.info().log("Could not read application frame; assuming portrait orientation")
            return .portrait
        }

        if appFrame.width > appFrame.height {
            logger.info().log(
                "Detected landscape orientation from application frame \(Int(appFrame.width))x\(Int(appFrame.height))"
            )
            return .landscape
        }

        logger.info().log(
            "Detected portrait orientation from application frame \(Int(appFrame.width))x\(Int(appFrame.height))"
        )
        return .portrait
    }
}
