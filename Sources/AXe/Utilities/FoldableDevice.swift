import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import FBSimulatorServices

// MARK: - Hinge Rules

/// Hinge angle rules shared by `axe hinge` and batch `hinge` steps.
enum HingeRules {
    static let range: ClosedRange<Double> = 0...180
    /// An instant jump between 0 and 180 degrees left the iOS 27.1 runtime unable to switch
    /// screens until the simulator was recreated, so on runtimes before `directSetRuntime` every
    /// change is a sweep of at least this length. `axe hinge sweep` always lasts at least this long.
    static let minimumSweepDuration: TimeInterval = 0.4
    /// The first runtime on which a direct 0-180 set switches displays reliably (verified 5/5 on
    /// the iPhone Duo with iOS 27.2).
    static let directSetRuntime = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)
    /// Interval between the angles of a sweep.
    static let sweepStepInterval: TimeInterval = 1.0 / 30
    /// The largest change between two angles of a sweep. Each angle is a round trip to the
    /// simulator; on a loaded host a time-sliced sweep would otherwise send a few large jumps.
    static let maximumSweepStep: Double = 10
    static let maximumDuration: TimeInterval = 30
    /// The cover display is expected at or below this angle.
    static let coverMaximumDegrees: Double = 30
    /// The inner display is expected at or above this angle.
    static let innerMinimumDegrees: Double = 120
    static let endpointTolerance: Double = 0.5
    /// iOS 27.2 settles intermediate angles within a few degrees of the requested one.
    static let intermediateTolerance: Double = 5
    static let angleConfirmTimeout: TimeInterval = 3
    static let displaySwitchTimeout: TimeInterval = 8
    static let displayPollInterval: TimeInterval = 0.5

    static func validate(_ degrees: Double, name: String = "Angle") throws {
        guard degrees.isFinite, range.contains(degrees) else {
            throw ValidationError("\(name) must be a number from 0 to 180 degrees; got \(formatted(degrees)).")
        }
    }

    /// Whether `runtime` takes a hinge change as one direct set instead of a sweep.
    static func allowsDirectSet(runtime: OperatingSystemVersion) -> Bool {
        (runtime.majorVersion, runtime.minorVersion) >= (directSetRuntime.majorVersion, directSetRuntime.minorVersion)
    }

    /// The duration of a move to an angle: `requested`, at least `minimumSweepDuration` unless the
    /// runtime takes direct sets. Zero means one direct set.
    static func sweepDuration(requested: TimeInterval, directSetAllowed: Bool = false) -> TimeInterval {
        directSetAllowed ? requested : max(requested, minimumSweepDuration)
    }

    static func tolerance(for target: Double) -> Double {
        target <= range.lowerBound || target >= range.upperBound ? endpointTolerance : intermediateTolerance
    }

    static func isConfirmed(reported: Double, target: Double) -> Bool {
        abs(reported - target) <= tolerance(for: target)
    }

    /// The display a foldable is expected to show at `degrees`; `nil` in the hand-over range.
    static func expectedPanel(for degrees: Double) -> FoldablePanel? {
        if degrees <= coverMaximumDegrees {
            return .cover
        }
        if degrees >= innerMinimumDegrees {
            return .inner
        }
        return nil
    }

    /// The endpoint farthest from `degrees`, assumed as the start when the angle cannot be read.
    static func oppositeEndpoint(of degrees: Double) -> Double {
        degrees >= 90 ? range.lowerBound : range.upperBound
    }

    /// The moves that take the hinge to `target`.
    ///
    /// - Parameters:
    ///   - current: the reported angle, or `nil` when it could not be read; the opposite endpoint
    ///     of the first destination is assumed then.
    ///   - start: the explicit start of `axe hinge sweep`. When the hinge is elsewhere, it first
    ///     moves there (directly, or over the minimum sweep duration). The sweep from `start` to
    ///     `target` always lasts at least `minimumSweepDuration`.
    ///   - directSetAllowed: the runtime takes direct sets (`allowsDirectSet(runtime:)`), so a move
    ///     with a zero duration is one direct set.
    static func sweepPlan(
        current: Double?,
        start: Double?,
        target: Double,
        duration: TimeInterval,
        directSetAllowed: Bool = false
    ) -> [HingeSweep] {
        guard let start else {
            let move = sweepDuration(requested: duration, directSetAllowed: directSetAllowed)
            return [HingeSweep(from: current ?? oppositeEndpoint(of: target), to: target, duration: move)]
        }
        let origin = current ?? oppositeEndpoint(of: start)
        var plan: [HingeSweep] = []
        if abs(origin - start) > tolerance(for: start) {
            plan.append(HingeSweep(from: origin, to: start, duration: sweepDuration(requested: 0, directSetAllowed: directSetAllowed)))
        }
        plan.append(HingeSweep(from: start, to: target, duration: max(duration, minimumSweepDuration)))
        return plan
    }

    /// The angle `progress` (0...1) of the way through a sweep, eased in and out
    /// (`t * t * (3 - 2t)`), so the hinge starts and stops gently like Device Hub's slider.
    static func easedAngle(from: Double, to: Double, progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return min(max(from + (to - from) * eased, range.lowerBound), range.upperBound)
    }

    /// `target`, or the angle `maximumSweepStep` from `current` toward it when it is farther away.
    static func limitedStep(from current: Double, toward target: Double) -> Double {
        let delta = target - current
        guard abs(delta) > maximumSweepStep else { return target }
        return current + (delta > 0 ? maximumSweepStep : -maximumSweepStep)
    }

    static func formatted(_ degrees: Double) -> String {
        String(format: "%.1f", degrees)
    }
}

/// One move of the hinge: a sweep from `from` to `to`, or a direct set when `duration` is 0.
struct HingeSweep: Equatable {
    let from: Double
    let to: Double
    let duration: TimeInterval

    var isDirectSet: Bool {
        duration <= 0
    }
}

enum FoldablePanel: String, Codable, Equatable {
    case cover
    case inner
}

// MARK: - Orientation

/// Interface orientation of the active display, named as AXe's `SimulatorOrientation`.
enum InterfaceOrientation: String, CaseIterable, ExpressibleByArgument, Codable {
    case portrait
    case landscape
    case portraitUpsideDown = "portrait-upside-down"
    case landscapeFlipped = "landscape-flipped"

    /// Device orientations tried on a foldable after `deviceOrientation`, in order. The same
    /// device orientation rotates the cover and inner displays differently, so the target is
    /// found by reading the display rotation back.
    static let foldableSearchOrder: [SimulatorDeviceOrientation] = [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown]

    init(rotation: SimulatorDisplay.Rotation) {
        switch rotation {
        case .rot0:
            self = .portrait
        case .rot90:
            self = .landscape
        case .rot180:
            self = .portraitUpsideDown
        case .rot270:
            self = .landscapeFlipped
        }
    }

    /// The display rotation that shows this interface orientation.
    var rotation: SimulatorDisplay.Rotation {
        switch self {
        case .portrait:
            return .rot0
        case .landscape:
            return .rot90
        case .portraitUpsideDown:
            return .rot180
        case .landscapeFlipped:
            return .rot270
        }
    }

    /// The device orientation that shows this interface orientation on a single-display simulator
    /// and on the cover display of a foldable.
    ///
    /// Measured on iOS 27.2 with Safari in the foreground: device `landscapeRight` shows rot90
    /// (AXe `landscape`); device `landscapeLeft` shows rot270.
    var deviceOrientation: SimulatorDeviceOrientation {
        switch self {
        case .portrait:
            return .portrait
        case .landscape:
            return .landscapeRight
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeFlipped:
            return .landscapeLeft
        }
    }

    /// Device orientations to try, in order: `deviceOrientation` alone on a single-display
    /// simulator; on a foldable, `deviceOrientation` and then the rest of `foldableSearchOrder`.
    func candidateDeviceOrientations(isFoldable: Bool) -> [SimulatorDeviceOrientation] {
        guard isFoldable else { return [deviceOrientation] }
        return [deviceOrientation] + Self.foldableSearchOrder.filter { $0 != deviceOrientation }
    }
}

// MARK: - Posture

enum DisplayRole: String, Encodable, Equatable {
    case cover
    case inner
    case main
    /// A non-integrated display that is the device's only display: an Apple TV's `TVOut`.
    case external
}

/// Hinge angle and display state of a simulator, printed by `axe posture`, `axe hinge` and `axe rotate`.
struct DevicePosture: Encodable, Equatable {
    struct Size: Encodable, Equatable {
        let width: Double
        let height: Double
    }

    struct Display: Encodable, Equatable {
        let id: Int
        let name: String
        let uniqueId: String
        let role: DisplayRole
        let primary: Bool
        let active: Bool
        let backlight: String?
        let rotation: String?
        let interfaceOrientation: InterfaceOrientation?
        /// Size in points as the interface sees it: native size over point scale, swapped for rot90/rot270.
        let sizePoints: Size?

        private enum CodingKeys: String, CodingKey {
            case id, name, uniqueId, role, primary, active, backlight, rotation, interfaceOrientation, sizePoints
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(uniqueId, forKey: .uniqueId)
            try container.encode(role, forKey: .role)
            try container.encode(primary, forKey: .primary)
            try container.encode(active, forKey: .active)
            try container.encode(backlight, forKey: .backlight)
            try container.encode(rotation, forKey: .rotation)
            try container.encode(interfaceOrientation, forKey: .interfaceOrientation)
            try container.encode(sizePoints, forKey: .sizePoints)
        }
    }

    let udid: String
    let hingeAngle: Double?
    let activeDisplay: Display?
    let deviceOrientation: String?
    let displays: [Display]
    /// devicectl could not be read: the backlight and device orientation are unknown, and display
    /// IDs come from AXe's cache when it has them. Not encoded; the JSON carries nulls.
    let devicectlUnavailable: Bool

    init(udid: String, hingeAngle: Double?, state: SimulatorDisplayState, devicectlUnavailable: Bool = false) {
        self.udid = udid
        self.hingeAngle = hingeAngle
        self.deviceOrientation = state.deviceOrientation
        self.devicectlUnavailable = devicectlUnavailable
        let active = state.activeDisplay
        let displays = state.displays.map { display in
            Self.makeDisplay(display, isMultiDisplay: state.isMultiDisplay, isActive: active.map(display.isSameDisplay(as:)) ?? false)
        }
        self.displays = displays
        self.activeDisplay = displays.first(where: \.active)
    }

    var activePanel: FoldablePanel? {
        switch activeDisplay?.role {
        case .cover:
            return .cover
        case .inner:
            return .inner
        case .main, .external, nil:
            return nil
        }
    }

    /// The interface size in points: the native size turned by the display's rotation.
    ///
    /// devicectl reports an Apple TV's TVOut with a 0x0 native size; an external display, or one
    /// reported that way, is sized from its bounds instead, divided by its point scale when one is
    /// reported. An integrated display without a usable native size and point scale has no size:
    /// its bounds are pixels in the native orientation and say nothing about the interface.
    static func interfaceSize(of display: SimulatorDisplay) -> Size? {
        guard let native = display.nativeSizePoints, native.width > 0, native.height > 0 else {
            let zeroNativeSize = display.nativeSize.map { $0.width == 0 && $0.height == 0 } ?? false
            guard !display.isIntegrated || zeroNativeSize,
                  let bounds = display.bounds, bounds.width > 0, bounds.height > 0 else { return nil }
            let scale = display.pointScale.flatMap { $0 > 0 ? $0 : nil } ?? 1
            return Size(width: bounds.width / scale, height: bounds.height / scale)
        }
        switch display.currentRotation {
        case .rot90, .rot270:
            return Size(width: native.height, height: native.width)
        case .rot0, .rot180, nil:
            return Size(width: native.width, height: native.height)
        }
    }

    private static func makeDisplay(_ display: SimulatorDisplay, isMultiDisplay: Bool, isActive: Bool) -> Display {
        let role: DisplayRole
        if !display.isIntegrated {
            role = .external
        } else {
            role = isMultiDisplay ? (display.primary ? .cover : .inner) : .main
        }
        return Display(
            id: display.displayId,
            name: display.name,
            uniqueId: display.uniqueId,
            role: role,
            primary: display.primary,
            active: isActive,
            backlight: display.backlightState,
            rotation: display.currentOrientation,
            interfaceOrientation: display.currentRotation.map(InterfaceOrientation.init(rotation:)),
            sizePoints: interfaceSize(of: display)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case udid, hingeAngle, activeDisplay, deviceOrientation, displays
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(udid, forKey: .udid)
        // Explicit nulls: scripts can test `hingeAngle == null` for a simulator without a hinge.
        try container.encode(hingeAngle, forKey: .hingeAngle)
        try container.encode(activeDisplay, forKey: .activeDisplay)
        try container.encode(deviceOrientation, forKey: .deviceOrientation)
        try container.encode(displays, forKey: .displays)
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    var textSummary: String {
        var lines: [String] = []
        lines.append("hinge angle: \(hingeAngle.map(HingeRules.formatted) ?? "none")")
        if let activeDisplay {
            lines.append("active display: \(describe(activeDisplay))")
        } else {
            lines.append("active display: unknown")
        }
        if let deviceOrientation {
            lines.append("device orientation: \(deviceOrientation)")
        } else if devicectlUnavailable {
            lines.append("device orientation: unknown")
        }
        lines.append("displays:")
        for display in displays {
            lines.append("  \(describe(display))\(display.active ? " (active)" : "")")
        }
        return lines.joined(separator: "\n")
    }

    private func describe(_ display: Display) -> String {
        let id = display.id == SimulatorDisplay.unknownDisplayID ? "unknown" : String(display.id)
        var parts = ["\(display.name) (id \(id), \(display.role.rawValue)\(display.primary ? ", primary" : ""))"]
        if let rotation = display.rotation {
            let orientation = display.interfaceOrientation.map { " \($0.rawValue)" } ?? ""
            parts.append("\(rotation)\(orientation)")
        }
        if let size = display.sizePoints {
            parts.append("\(Self.formatPoints(size.width))x\(Self.formatPoints(size.height)) pt")
        }
        if let backlight = display.backlight {
            parts.append("backlight \(backlight)")
        } else if devicectlUnavailable {
            parts.append("backlight unknown")
        }
        return parts.joined(separator: ", ")
    }

    private static func formatPoints(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}

// MARK: - Device State Actions

/// A hinge or rotation change, run by `axe hinge`, `axe rotate` and batch barrier steps.
enum DeviceStateAction: Equatable {
    case hinge(target: Double, duration: TimeInterval, waitForDisplay: Bool)
    case sweep(from: Double, to: Double, duration: TimeInterval, waitForDisplay: Bool)
    case rotate(InterfaceOrientation)

    var isHingeAction: Bool {
        switch self {
        case .hinge, .sweep:
            return true
        case .rotate:
            return false
        }
    }

    /// Whether the action polls display state: a rotation, or a hinge move that waits for the display.
    var readsDisplays: Bool {
        switch self {
        case .hinge(_, _, let waitForDisplay), .sweep(_, _, _, let waitForDisplay):
            return waitForDisplay
        case .rotate:
            return true
        }
    }
}

/// Result of reading the hinge angle.
enum HingeAngleReading: Equatable {
    case angle(Double)
    /// The simulator reports no hinge: not a foldable, or a runtime older than iOS 27.1.
    case noHinge
    case unreadable(String)
}

/// The simulator operations behind hinge and rotation actions. Live code calls IDB's hinge,
/// orientation and display commands; tests inject fakes.
@MainActor
struct FoldableDriver {
    var readAngle: () async throws -> HingeAngleReading
    /// Sends one hinge angle, unconfirmed.
    var setAngle: (Double) async throws -> Void
    /// Reads display state without the cache, once any transition has settled within the given
    /// seconds; throws `DisplaysStillChangingError` when it has not. Never runs devicectl.
    var readDisplays: (TimeInterval) async throws -> SimulatorDisplayState
    var setDeviceOrientation: (SimulatorDeviceOrientation) async throws -> Void
    var readDeviceOrientation: () async throws -> SimulatorDeviceOrientation?
    var sleep: (TimeInterval) async throws -> Void
    var now: () -> Date
    var log: (String) -> Void

    static func live(simulator: Simulator, logger: AxeLogger) -> FoldableDriver {
        FoldableDriver(
            readAngle: {
                try await FoldableDevice.readAngle(simulator: simulator)
            },
            setAngle: { degrees in
                try await simulator.hinge.set(try SimulatorHingeAngle(degrees: min(max(degrees, 0), 180)))
            },
            readDisplays: { budget in
                // Display IDs come from the cache, filled once before the action (`perform`).
                try await SimulatorDisplays.readConfiguration(of: simulator, logger: logger, settleBudget: budget, lookUpDisplayIDs: false)
            },
            setDeviceOrientation: { orientation in
                try await simulator.orientation.set(orientation)
            },
            readDeviceOrientation: {
                try await simulator.orientation.current()
            },
            sleep: { seconds in
                try await Task.sleep(for: .seconds(seconds))
            },
            now: Date.init,
            log: { message in
                logger.info().log(message)
            }
        )
    }
}

@MainActor
enum FoldableDevice {
    /// How long each rotation candidate may take to show up in the display state.
    static let rotationTimeout: TimeInterval = 2
    static let rotationPollInterval: TimeInterval = 0.2

    nonisolated static func noHingeError(simulatorUDID: String) -> CLIError {
        CLIError(
            errorDescription: "Simulator \(simulatorUDID) reports no hinge. Hinge commands need a foldable simulator (iPhone Duo) with an iOS 27.1 or later runtime."
        )
    }

    /// Throws `noHingeError` unless the simulator reports a hinge.
    nonisolated static func ensureHingeSupported(hasHinge: Bool, simulatorUDID: String) throws {
        guard hasHinge else {
            throw noHingeError(simulatorUDID: simulatorUDID)
        }
    }

    /// Looks up a booted simulator.
    static func bootedSimulator(udid: String, logger: AxeLogger) async throws -> Simulator {
        try SimulatorSession.bootedSimulator(udid: udid, logger: logger)
    }

    // MARK: Reading

    /// The hinge angle IDB reads from the simulator's motion provider.
    nonisolated static func readAngle(simulator: Simulator) async throws -> HingeAngleReading {
        do {
            return .angle(try await simulator.hinge.current().degrees)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if case .unsupported = SimulatorFailureKind(error) {
                return .noHinge
            }
            return .unreadable(error.localizedDescription)
        }
    }

    /// The hinge angle of a foldable; throws for simulators without one.
    static func requireAngle(simulator: Simulator, logger: AxeLogger) async throws -> Double {
        switch try await readAngle(simulator: simulator) {
        case .angle(let value):
            return value
        case .noHinge:
            throw noHingeError(simulatorUDID: simulator.udid)
        case .unreadable(let detail):
            throw CLIError(errorDescription: "AXe could not read the hinge angle of simulator \(simulator.udid): \(detail)")
        }
    }

    /// Posture of any simulator: the hinge angle (`nil` without a hinge) from IDB, and the
    /// displays from devicectl (display IDs, backlight, device orientation) with the activity,
    /// rotation and size IDB reports. The three reads run concurrently.
    ///
    /// - Parameter settled: `false` reads IDB's displays as they are right now, without waiting for
    ///   a fold to settle (after `hinge --no-wait`); they may still be the outgoing displays.
    static func posture(simulator: Simulator, settled: Bool = true, logger: AxeLogger) async throws -> DevicePosture {
        async let angle = readAngle(simulator: simulator)
        async let displays = postureDisplays(of: simulator, settled: settled, logger: logger)
        let angleValue: Double?
        if case .angle(let value) = try await angle {
            angleValue = value
        } else {
            angleValue = nil
        }
        let result = try await displays
        return DevicePosture(udid: simulator.udid, hingeAngle: angleValue, state: result.state, devicectlUnavailable: result.devicectlUnavailable)
    }

    /// Posture with an angle the caller already read.
    static func posture(simulator: Simulator, hingeAngle: Double?, logger: AxeLogger) async throws -> DevicePosture {
        let result = try await postureDisplays(of: simulator, settled: true, logger: logger)
        return DevicePosture(udid: simulator.udid, hingeAngle: hingeAngle, state: result.state, devicectlUnavailable: result.devicectlUnavailable)
    }

    /// devicectl's displays with IDB's activity, rotation and size laid over them; both reads run
    /// concurrently. When devicectl fails, IDB's displays alone, with a warning on stderr: the
    /// backlight and device orientation are then unknown and display IDs come from the cache.
    private static func postureDisplays(
        of simulator: Simulator,
        settled: Bool,
        logger: AxeLogger
    ) async throws -> (state: SimulatorDisplayState, devicectlUnavailable: Bool) {
        SimulatorDisplays.invalidateCachedState()
        async let configuration = readConfigurationIfAvailable(of: simulator, settled: settled, logger: logger)
        let devicectl: SimulatorDisplayState
        do {
            devicectl = try await SimulatorDisplays.readWithDevicectl(simulatorUDID: simulator.udid, logger: logger)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let idb = await configuration else { throw error }
            let detail = (error as? DevicectlDisplayReadError)?.detail ?? error.localizedDescription
            print(
                "Warning: `xcrun devicectl device info displays` failed\(detail.isEmpty ? "" : " (\(detail))"); printing the displays IDB reports. The backlight and device orientation are unknown.",
                to: &standardError
            )
            return (idb, true)
        }
        guard let idb = await configuration else { return (devicectl, false) }
        return (devicectl.overlaying(idb), false)
    }

    /// IDB's display configuration with display IDs from the cache only; `nil` when the runtime
    /// does not report one, or (with `settled`) when it is still changing.
    private static func readConfigurationIfAvailable(of simulator: Simulator, settled: Bool, logger: AxeLogger) async -> SimulatorDisplayState? {
        do {
            let configuration = settled
                ? try await SimulatorDisplays.settledConfiguration(of: simulator, within: SimulatorDisplays.settleBudget, logger: logger)
                : try await SimulatorDisplays.configuration(of: simulator, settledWithin: 0)
            return SimulatorDisplayState(
                configuration: configuration,
                displayIDs: DisplayIDCache.ids(forSimulatorUDID: simulator.udid) ?? [:]
            )
        } catch {
            logger.info().log("IDB display configuration unavailable for posture: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Actions

    /// Runs `action`. Returns a warning when the device took the change but the interface did not follow.
    @discardableResult
    static func perform(_ action: DeviceStateAction, simulator: Simulator, logger: AxeLogger) async throws -> String? {
        // watchOS, tvOS and visionOS report no orientation or hinge; refuse before Device Hub.
        try PlatformSupport.requireIOS(command: action.isHingeAction ? "hinge" : "rotate", on: simulator.platform)
        defer { SimulatorDisplays.invalidateCachedState() }
        let capabilities = try await simulator.capabilities()
        if action.isHingeAction {
            try ensureHingeSupported(hasHinge: capabilities.hingeAngle, simulatorUDID: simulator.udid)
        }
        if capabilities.multipleDisplays, action.readsDisplays {
            // The polling loops read display IDs from the cache only, so a slow or failing
            // devicectl costs at most this one read.
            await SimulatorDisplays.prefetchDisplayIDs(of: simulator, logger: logger)
        }
        return try await perform(
            action,
            isFoldable: capabilities.multipleDisplays,
            directSetAllowed: HingeRules.allowsDirectSet(runtime: simulator.osVersion.version),
            simulatorUDID: simulator.udid,
            driver: .live(simulator: simulator, logger: logger)
        )
    }

    static func perform(
        _ action: DeviceStateAction,
        isFoldable: Bool,
        directSetAllowed: Bool = false,
        simulatorUDID: String,
        driver: FoldableDriver
    ) async throws -> String? {
        switch action {
        case .hinge(let target, let duration, let waitForDisplay):
            try await moveHinge(from: nil, to: target, duration: duration, waitForDisplay: waitForDisplay, directSetAllowed: directSetAllowed, simulatorUDID: simulatorUDID, driver: driver)
            return nil
        case .sweep(let from, let to, let duration, let waitForDisplay):
            try await moveHinge(from: from, to: to, duration: duration, waitForDisplay: waitForDisplay, directSetAllowed: directSetAllowed, simulatorUDID: simulatorUDID, driver: driver)
            return nil
        case .rotate(let orientation):
            return try await rotate(to: orientation, isFoldable: isFoldable, simulatorUDID: simulatorUDID, driver: driver)
        }
    }

    /// Moves the hinge to `target` through the moves from `HingeRules.sweepPlan`, confirms the
    /// reported angle, and optionally waits for the expected display to become active.
    static func moveHinge(
        from start: Double?,
        to target: Double,
        duration: TimeInterval,
        waitForDisplay: Bool,
        directSetAllowed: Bool = false,
        simulatorUDID: String,
        driver: FoldableDriver
    ) async throws {
        try HingeRules.validate(target)
        if let start {
            try HingeRules.validate(start, name: "Start angle")
        }

        let current: Double?
        switch try await driver.readAngle() {
        case .angle(let value):
            current = value
        case .noHinge:
            throw noHingeError(simulatorUDID: simulatorUDID)
        case .unreadable(let detail):
            driver.log("Hinge angle unreadable (\(detail)); sweeping from the opposite endpoint")
            current = nil
        }

        let plan = HingeRules.sweepPlan(current: current, start: start, target: target, duration: duration, directSetAllowed: directSetAllowed)
        for sweep in plan {
            try await run(sweep, driver: driver)
        }

        try await confirmAngle(target, simulatorUDID: simulatorUDID, driver: driver)

        guard waitForDisplay, let expected = HingeRules.expectedPanel(for: target) else {
            return
        }
        try await waitForActivePanel(expected, angle: target, driver: driver)
    }

    /// Sends one move: a direct set, or eased angles every `HingeRules.sweepStepInterval` until
    /// the sweep's duration has passed, ending exactly at its target.
    ///
    /// No two angles are more than `HingeRules.maximumSweepStep` apart: when each set takes longer
    /// than the step interval (a loaded host), the sweep falls behind its clock and takes more
    /// time rather than jumping.
    static func run(_ sweep: HingeSweep, driver: FoldableDriver) async throws {
        guard !sweep.isDirectSet else {
            driver.log("Setting the hinge to \(HingeRules.formatted(sweep.to))")
            try await driver.setAngle(sweep.to)
            return
        }
        driver.log("Sweeping the hinge from \(HingeRules.formatted(sweep.from)) to \(HingeRules.formatted(sweep.to)) over \(sweep.duration) s")
        let started = driver.now()
        var current = sweep.from
        var sent = 0
        while true {
            let elapsed = driver.now().timeIntervalSince(started)
            let progress = min(elapsed / sweep.duration, 1)
            let scheduled = HingeRules.easedAngle(from: sweep.from, to: sweep.to, progress: progress)
            let angle = sent == 0 ? sweep.from : HingeRules.limitedStep(from: current, toward: scheduled)
            try await driver.setAngle(angle)
            current = angle
            sent += 1
            if progress >= 1, angle == sweep.to {
                break
            }
            let remaining = sweep.duration - elapsed
            if remaining > 0 {
                try await driver.sleep(min(HingeRules.sweepStepInterval, remaining))
            }
        }
        let took = driver.now().timeIntervalSince(started)
        driver.log("Sent \(sent) hinge angles in \(String(format: "%.2f", took)) s")
    }

    private static func confirmAngle(_ target: Double, simulatorUDID: String, driver: FoldableDriver) async throws {
        let deadline = driver.now().addingTimeInterval(HingeRules.angleConfirmTimeout)
        var last: HingeAngleReading = .unreadable("no reading")
        repeat {
            last = try await driver.readAngle()
            switch last {
            case .angle(let reported) where HingeRules.isConfirmed(reported: reported, target: target):
                driver.log("Hinge angle confirmed at \(HingeRules.formatted(reported))")
                return
            case .noHinge:
                throw noHingeError(simulatorUDID: simulatorUDID)
            case .angle, .unreadable:
                try await driver.sleep(0.1)
            }
        } while driver.now() < deadline

        let lastText: String
        switch last {
        case .angle(let value):
            lastText = "the simulator reports \(HingeRules.formatted(value)) degrees"
        case .noHinge:
            lastText = "the simulator reports no hinge"
        case .unreadable(let detail):
            lastText = "the angle could not be read (\(detail))"
        }
        throw CLIError(
            errorDescription: "The hinge angle did not reach \(HingeRules.formatted(target)) degrees within \(Int(HingeRules.angleConfirmTimeout)) s; \(lastText). The private Device Hub hinge event may have changed in this Xcode or runtime."
        )
    }

    private static func waitForActivePanel(_ expected: FoldablePanel, angle: Double, driver: FoldableDriver) async throws {
        let deadline = driver.now().addingTimeInterval(HingeRules.displaySwitchTimeout)
        var lastActive: SimulatorDisplay?
        repeat {
            // Each read may wait for the fold to settle, but only within what is left of the timeout.
            let remaining = deadline.timeIntervalSince(driver.now())
            do {
                let state = try await driver.readDisplays(max(remaining, 0))
                lastActive = state.activeDisplay
                if let active = lastActive, state.isMultiDisplay, (active.primary ? FoldablePanel.cover : .inner) == expected {
                    driver.log("Display \(active.label) is active")
                    return
                }
            } catch is DisplaysStillChangingError {
                driver.log("Displays still changing; polling again")
            }
            if driver.now() < deadline {
                try await driver.sleep(HingeRules.displayPollInterval)
            }
        } while driver.now() < deadline

        let activeText = lastActive.map { "\($0.label), \($0.primary ? "cover" : "inner")" } ?? "unknown"
        throw CLIError(
            errorDescription: "The \(expected.rawValue) display did not become active within \(Int(HingeRules.displaySwitchTimeout)) s after setting the hinge to \(HingeRules.formatted(angle)) degrees; the active display is \(activeText). Send the angle again after a moment; if the display still does not switch, shut down and boot the simulator again."
        )
    }

    /// Polls display state until the active display reports `target` or the timeout passes. Stops
    /// early when the display settles on a different rotation than `previous`, since that candidate
    /// rotated the display somewhere else.
    private static func waitForRotation(
        _ target: SimulatorDisplay.Rotation,
        previous: SimulatorDisplay.Rotation? = nil,
        timeout: TimeInterval,
        driver: FoldableDriver
    ) async throws -> (matched: Bool, state: SimulatorDisplayState?) {
        let deadline = driver.now().addingTimeInterval(timeout)
        var state: SimulatorDisplayState?
        repeat {
            try await driver.sleep(rotationPollInterval)
            do {
                state = try await driver.readDisplays(max(deadline.timeIntervalSince(driver.now()), 0))
            } catch is DisplaysStillChangingError {
                continue
            }
            let rotation = state?.activeDisplay?.currentRotation
            if rotation == target {
                return (true, state)
            }
            if let previous, let rotation, rotation != previous {
                return (false, state)
            }
        } while driver.now() < deadline
        return (false, state)
    }

    /// Sets `deviceOrientation` again and reports whether the active display returned to `rotation`.
    private static func restoreDeviceOrientation(
        _ deviceOrientation: SimulatorDeviceOrientation,
        rotation: SimulatorDisplay.Rotation,
        driver: FoldableDriver
    ) async -> Bool {
        do {
            try await driver.setDeviceOrientation(deviceOrientation)
            let matched = try await waitForRotation(rotation, timeout: rotationTimeout, driver: driver).matched
            driver.log("Restoring device orientation \(deviceOrientation.rawValue): display \(matched ? "back at" : "not back at") \(rotation.rawValue)")
            return matched
        } catch {
            driver.log("Restoring device orientation \(deviceOrientation.rawValue) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Sends each device orientation in turn until the active display reports `target`.
    private static func searchRotation(
        _ target: SimulatorDisplay.Rotation,
        candidates: [SimulatorDeviceOrientation],
        from initial: SimulatorDisplayState?,
        driver: FoldableDriver
    ) async throws -> (matched: Bool, state: SimulatorDisplayState?) {
        var lastState = initial
        for candidate in candidates {
            let previous = lastState?.activeDisplay?.currentRotation
            try await driver.setDeviceOrientation(candidate)
            let result = try await waitForRotation(target, previous: previous, timeout: rotationTimeout, driver: driver)
            lastState = result.state ?? lastState
            if result.matched {
                driver.log("Device orientation \(candidate.rawValue) gives \(target.rawValue)")
                return (true, lastState)
            }
        }
        return (false, lastState)
    }

    /// Rotates the interface of the active display to `orientation`, verified by the display
    /// rotation the simulator reports.
    ///
    /// A single-display simulator gets `InterfaceOrientation.deviceOrientation`. If its display
    /// does not follow, the call returns a warning when the device took the orientation (the
    /// foreground app or screen does not rotate, for example an iPhone home screen) and throws
    /// otherwise.
    ///
    /// A foldable tries device orientations until the active display reports the rotation: the
    /// same device orientation rotates the cover and inner displays differently. On failure the
    /// original device orientation is set again (so the inactive display is also left as it was);
    /// when that cannot be read or does not bring the starting rotation back, the starting
    /// rotation is searched for, so the device is not left upside down.
    static func rotate(
        to orientation: InterfaceOrientation,
        isFoldable: Bool,
        simulatorUDID: String,
        driver: FoldableDriver
    ) async throws -> String? {
        let target = orientation.rotation
        let initial = try await driver.readDisplays(SimulatorDisplays.settleBudget)
        let startRotation = initial.activeDisplay?.currentRotation
        if startRotation == target {
            driver.log("Active display already at \(target.rawValue)")
            return nil
        }
        let originalDeviceOrientation: SimulatorDeviceOrientation? = isFoldable ? (try? await driver.readDeviceOrientation()) ?? nil : nil

        let candidates = orientation.candidateDeviceOrientations(isFoldable: isFoldable)
        let search = try await searchRotation(target, candidates: candidates, from: initial, driver: driver)
        if search.matched {
            return nil
        }
        let current = search.state?.activeDisplay?.currentOrientation ?? "unknown"

        guard isFoldable else {
            let value = orientation.deviceOrientation
            let reported = try? await driver.readDeviceOrientation()
            guard reported == value else {
                throw CLIError(
                    errorDescription: "Simulator \(simulatorUDID) did not take device orientation \(value.rawValue) for \(orientation.rawValue); it reports \(reported?.rawValue ?? "unknown")."
                )
            }
            return "The device orientation is now \(value.rawValue), but the active display still reports \(current) instead of \(target.rawValue) (\(orientation.rawValue)). The foreground app or screen may not support \(orientation.rawValue)."
        }

        var restoreNote = ""
        if let startRotation {
            if let originalDeviceOrientation,
               await restoreDeviceOrientation(originalDeviceOrientation, rotation: startRotation, driver: driver) {
                restoreNote = " The device orientation was returned to \(originalDeviceOrientation.rawValue) and the display to \(startRotation.rawValue)."
            } else {
                let restoreCandidates = InterfaceOrientation(rotation: startRotation).candidateDeviceOrientations(isFoldable: true)
                let restored = (try? await searchRotation(startRotation, candidates: restoreCandidates, from: search.state, driver: driver))?.matched ?? false
                restoreNote = restored
                    ? " The display was returned to \(startRotation.rawValue)."
                    : " The display could not be returned to \(startRotation.rawValue)."
            }
        }
        let name = initial.activeDisplay?.name ?? ""
        throw CLIError(
            errorDescription: "The active display \(name) did not rotate to \(orientation.rawValue) (\(target.rawValue)); it reported \(current) after trying device orientations \(candidates.map(\.rawValue).joined(separator: ", ")). The foreground app may not support that orientation.\(restoreNote)"
        )
    }
}
