import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Hinge Rules

/// Hinge angle rules shared by `axe hinge` and batch `hinge` steps.
enum HingeRules {
    static let range: ClosedRange<Double> = 0...180
    /// An instant jump between 0 and 180 degrees leaves the iOS 27.1 runtime unable to switch
    /// screens until the simulator is recreated, so every change is a sweep of at least this length.
    static let minimumSweepDuration: TimeInterval = 0.4
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

    static func sweepDuration(requested: TimeInterval) -> TimeInterval {
        max(requested, minimumSweepDuration)
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

    /// The sweeps that move the hinge to `target`, never as an instant jump.
    ///
    /// - Parameters:
    ///   - current: the reported angle, or `nil` when it could not be read; the opposite endpoint
    ///     of the first destination is assumed then.
    ///   - start: the explicit start of `axe hinge sweep`. When the hinge is elsewhere, it first
    ///     sweeps there over the minimum duration.
    static func sweepPlan(current: Double?, start: Double?, target: Double, duration: TimeInterval) -> [HingeSweep] {
        let main = sweepDuration(requested: duration)
        guard let start else {
            return [HingeSweep(from: current ?? oppositeEndpoint(of: target), to: target, duration: main)]
        }
        let origin = current ?? oppositeEndpoint(of: start)
        var plan: [HingeSweep] = []
        if abs(origin - start) > tolerance(for: start) {
            plan.append(HingeSweep(from: origin, to: start, duration: minimumSweepDuration))
        }
        plan.append(HingeSweep(from: start, to: target, duration: main))
        return plan
    }

    static func formatted(_ degrees: Double) -> String {
        String(format: "%.1f", degrees)
    }
}

/// One `axe-sim-helper hinge-sweep` call.
struct HingeSweep: Equatable {
    let from: Double
    let to: Double
    let duration: TimeInterval

    var helperArguments: [String] {
        ["hinge-sweep", HingeRules.formatted(from), HingeRules.formatted(to), String(format: "%.3f", duration)]
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

    /// Device orientations the helper tries on a foldable, in order. The same device orientation
    /// rotates the cover and inner displays differently, so the target is found by readback.
    static let foldableSearchOrder = ["portrait", "landscape-left", "landscape-right", "pud"]

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

    /// devicectl `currentOrientation` that shows this interface orientation.
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

    /// `devicectl device orientation set` value for single-display simulators.
    ///
    /// Measured on iOS 27.2 with Safari in the foreground: device `landscapeRight` shows rot90
    /// (SimulatorKit uiOrientation 3, AXe `landscape`); device `landscapeLeft` shows rot270.
    var deviceOrientation: String {
        switch self {
        case .portrait:
            return "portrait"
        case .landscape:
            return "landscapeRight"
        case .portraitUpsideDown:
            return "portraitUpsideDown"
        case .landscapeFlipped:
            return "landscapeLeft"
        }
    }
}

// MARK: - Posture

enum DisplayRole: String, Encodable, Equatable {
    case cover
    case inner
    case main
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

    init(udid: String, hingeAngle: Double?, state: SimulatorDisplayState) {
        self.udid = udid
        self.hingeAngle = hingeAngle
        self.deviceOrientation = state.deviceOrientation
        let activeID = state.activeDisplay?.displayId
        let displays = state.displays.map { display in
            Self.makeDisplay(display, isMultiDisplay: state.isMultiDisplay, isActive: display.displayId == activeID)
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
        case .main, nil:
            return nil
        }
    }

    static func interfaceSize(of display: SimulatorDisplay) -> Size? {
        guard let native = display.nativeSizePoints else { return nil }
        switch display.currentRotation {
        case .rot90, .rot270:
            return Size(width: native.height, height: native.width)
        case .rot0, .rot180, nil:
            return Size(width: native.width, height: native.height)
        }
    }

    private static func makeDisplay(_ display: SimulatorDisplay, isMultiDisplay: Bool, isActive: Bool) -> Display {
        let role: DisplayRole = isMultiDisplay ? (display.primary ? .cover : .inner) : .main
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
            lines.append("active display: \(Self.describe(activeDisplay))")
        } else {
            lines.append("active display: unknown")
        }
        if let deviceOrientation {
            lines.append("device orientation: \(deviceOrientation)")
        }
        lines.append("displays:")
        for display in displays {
            lines.append("  \(Self.describe(display))\(display.active ? " (active)" : "")")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ display: Display) -> String {
        var parts = ["\(display.name) (id \(display.id), \(display.role.rawValue)\(display.primary ? ", primary" : ""))"]
        if let rotation = display.rotation {
            let orientation = display.interfaceOrientation.map { " \($0.rawValue)" } ?? ""
            parts.append("\(rotation)\(orientation)")
        }
        if let size = display.sizePoints {
            parts.append("\(formatPoints(size.width))x\(formatPoints(size.height)) pt")
        }
        if let backlight = display.backlight {
            parts.append("backlight \(backlight)")
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
}

/// Result of reading the hinge angle through the helper.
enum HingeAngleReading: Equatable {
    case angle(Double)
    /// CoreMotion reports no hinge: not a foldable, or a runtime older than iOS 27.1.
    case noHinge
    case unreadable(String)
}

/// The simulator operations behind hinge and rotation actions. Live code talks to the helper and
/// devicectl; tests inject fakes.
@MainActor
struct FoldableDriver {
    var readAngle: () async throws -> HingeAngleReading
    /// Runs the helper and throws when it fails.
    var runHelper: (_ arguments: [String], _ timeout: TimeInterval) async throws -> Void
    /// Reads display state without the cache.
    var readDisplays: () async throws -> SimulatorDisplayState
    var setDeviceOrientation: (String) async throws -> Void
    var readDeviceOrientation: () async throws -> String?
    var sleep: (TimeInterval) async throws -> Void
    var now: () -> Date
    var log: (String) -> Void

    static func live(simulatorUDID: String, logger: AxeLogger) -> FoldableDriver {
        FoldableDriver(
            readAngle: {
                try await FoldableDevice.readAngle(simulatorUDID: simulatorUDID, logger: logger)
            },
            runHelper: { arguments, timeout in
                try await SimHelper.runChecked(arguments, simulatorUDID: simulatorUDID, timeout: timeout, logger: logger)
            },
            readDisplays: {
                SimulatorDisplays.invalidateCachedState()
                return try await SimulatorDisplays.read(simulatorUDID: simulatorUDID, logger: logger)
            },
            setDeviceOrientation: { value in
                let result = try await XcrunProcess.run(
                    ["devicectl", "device", "orientation", "set", value, "-d", simulatorUDID, "-q"],
                    timeout: SimulatorDisplays.devicectlTimeout
                )
                guard result.status == 0 else {
                    let detail = result.failureDetail
                    throw CLIError(
                        errorDescription: "`xcrun devicectl device orientation set \(value)` failed for simulator \(simulatorUDID)" + (detail.isEmpty ? "." : ": \(detail)")
                    )
                }
            },
            readDeviceOrientation: {
                let result = try await XcrunProcess.run(
                    ["devicectl", "device", "orientation", "get", "-d", simulatorUDID, "-q", "-j", "-"],
                    timeout: SimulatorDisplays.devicectlTimeout
                )
                guard result.status == 0 else { return nil }
                return try DeviceOrientationEnvelope.decode(from: result.standardOutput)
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
    static let helperNoHingeMarker = "reports no hinge"
    /// How long each rotation candidate may take to show up in devicectl.
    static let rotationTimeout: TimeInterval = 2
    static let rotationPollInterval: TimeInterval = 0.2
    static let deviceOrientationTimeout: TimeInterval = 2

    nonisolated static func noHingeError(simulatorUDID: String) -> CLIError {
        CLIError(
            errorDescription: "Simulator \(simulatorUDID) reports no hinge. Hinge commands need a foldable simulator (iPhone Duo) with an iOS 27.1 or later runtime."
        )
    }

    /// Hinge commands run only on foldable device types, so other simulators never build or spawn the helper.
    nonisolated static func ensureHingeSupported(isFoldable: Bool, simulatorUDID: String) throws {
        guard isFoldable else {
            throw noHingeError(simulatorUDID: simulatorUDID)
        }
    }

    /// Looks up a booted simulator.
    static func bootedSimulator(udid: String, logger: AxeLogger) async throws -> FBSimulator {
        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == udid }) else {
            throw CLIError.simulatorNotFound(udid: udid)
        }
        guard simulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(simulator.state)
            throw CLIError(errorDescription: "Simulator \(udid) is not booted. Current state: \(stateDescription).")
        }
        return simulator
    }

    // MARK: Reading

    static func readAngle(simulatorUDID: String, logger: AxeLogger) async throws -> HingeAngleReading {
        let result = try await SimHelper.run(["hinge-angle"], simulatorUDID: simulatorUDID, logger: logger)
        let message = SimHelper.failureMessage(result)
        if result.status != 0 {
            return message.contains(helperNoHingeMarker) ? .noHinge : .unreadable(message)
        }
        let text = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text) else {
            return .unreadable("unexpected helper output '\(text)'")
        }
        return .angle(value)
    }

    /// The hinge angle of a foldable; throws for simulators without one.
    static func requireAngle(simulator: FBSimulator, logger: AxeLogger) async throws -> Double {
        try ensureHingeSupported(isFoldable: SimulatorDisplays.isFoldable(simulator), simulatorUDID: simulator.udid)
        switch try await readAngle(simulatorUDID: simulator.udid, logger: logger) {
        case .angle(let value):
            return value
        case .noHinge:
            throw noHingeError(simulatorUDID: simulator.udid)
        case .unreadable(let detail):
            throw CLIError(errorDescription: "AXe could not read the hinge angle of simulator \(simulator.udid): \(detail)")
        }
    }

    /// Posture of any simulator. The hinge angle is read only on foldable device types.
    static func posture(simulator: FBSimulator, logger: AxeLogger) async throws -> DevicePosture {
        var angle: Double?
        if SimulatorDisplays.isFoldable(simulator),
           case .angle(let value) = try await readAngle(simulatorUDID: simulator.udid, logger: logger) {
            angle = value
        }
        return try await posture(simulator: simulator, hingeAngle: angle, logger: logger)
    }

    /// Posture with an angle the caller already read.
    static func posture(simulator: FBSimulator, hingeAngle: Double?, logger: AxeLogger) async throws -> DevicePosture {
        SimulatorDisplays.invalidateCachedState()
        let state = try await SimulatorDisplays.read(simulatorUDID: simulator.udid, logger: logger)
        return DevicePosture(udid: simulator.udid, hingeAngle: hingeAngle, state: state)
    }

    // MARK: Actions

    /// Runs `action`. Returns a warning when the device took the change but the interface did not follow.
    @discardableResult
    static func perform(_ action: DeviceStateAction, simulator: FBSimulator, logger: AxeLogger) async throws -> String? {
        defer { SimulatorDisplays.invalidateCachedState() }
        let isFoldable = SimulatorDisplays.isFoldable(simulator)
        if action.isHingeAction {
            try ensureHingeSupported(isFoldable: isFoldable, simulatorUDID: simulator.udid)
        }
        return try await perform(
            action,
            isFoldable: isFoldable,
            simulatorUDID: simulator.udid,
            driver: .live(simulatorUDID: simulator.udid, logger: logger)
        )
    }

    static func perform(
        _ action: DeviceStateAction,
        isFoldable: Bool,
        simulatorUDID: String,
        driver: FoldableDriver
    ) async throws -> String? {
        switch action {
        case .hinge(let target, let duration, let waitForDisplay):
            try await moveHinge(from: nil, to: target, duration: duration, waitForDisplay: waitForDisplay, simulatorUDID: simulatorUDID, driver: driver)
            return nil
        case .sweep(let from, let to, let duration, let waitForDisplay):
            try await moveHinge(from: from, to: to, duration: duration, waitForDisplay: waitForDisplay, simulatorUDID: simulatorUDID, driver: driver)
            return nil
        case .rotate(let orientation):
            if isFoldable {
                try await rotateFoldable(to: orientation, driver: driver)
                return nil
            }
            return try await rotateSingleDisplay(to: orientation, simulatorUDID: simulatorUDID, driver: driver)
        }
    }

    /// Moves the hinge to `target` through the sweeps from `HingeRules.sweepPlan`, confirms the
    /// reported angle, and optionally waits for the expected display to become active.
    static func moveHinge(
        from start: Double?,
        to target: Double,
        duration: TimeInterval,
        waitForDisplay: Bool,
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

        for sweep in HingeRules.sweepPlan(current: current, start: start, target: target, duration: duration) {
            try await driver.runHelper(sweep.helperArguments, sweep.duration + SimHelper.defaultRunTimeout)
        }

        try await confirmAngle(target, simulatorUDID: simulatorUDID, driver: driver)

        guard waitForDisplay, let expected = HingeRules.expectedPanel(for: target) else {
            return
        }
        try await waitForActivePanel(expected, angle: target, driver: driver)
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
                try await driver.sleep(0.2)
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
            try await driver.sleep(HingeRules.displayPollInterval)
            let state = try await driver.readDisplays()
            lastActive = state.activeDisplay
            if let active = lastActive, state.isMultiDisplay, (active.primary ? FoldablePanel.cover : .inner) == expected {
                driver.log("Display \(active.displayId) (\(active.name)) is active")
                return
            }
        } while driver.now() < deadline

        let activeText = lastActive.map { "\($0.name) (id \($0.displayId), \($0.primary ? "cover" : "inner"))" } ?? "unknown"
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
            state = try await driver.readDisplays()
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

    /// Sends each helper device orientation in turn until the active display reports `target`.
    private static func searchRotation(
        _ target: SimulatorDisplay.Rotation,
        from initial: SimulatorDisplayState?,
        driver: FoldableDriver
    ) async throws -> (matched: Bool, state: SimulatorDisplayState?) {
        var lastState = initial
        for candidate in InterfaceOrientation.foldableSearchOrder {
            let previous = lastState?.activeDisplay?.currentRotation
            try await driver.runHelper(["orientation", candidate], SimHelper.defaultRunTimeout)
            let result = try await waitForRotation(target, previous: previous, timeout: rotationTimeout, driver: driver)
            lastState = result.state ?? lastState
            if result.matched {
                driver.log("Device orientation \(candidate) gives \(target.rawValue)")
                return (true, lastState)
            }
        }
        return (false, lastState)
    }

    /// Tries device orientations until the active display reports the requested rotation. On
    /// failure, the starting rotation is searched for again so the device is not left upside down.
    ///
    /// devicectl reports the device orientation in the cover display's frame, which is a quarter
    /// turn from the event values while the inner display is active, so the starting orientation
    /// is restored by its display rotation, not by name.
    static func rotateFoldable(to orientation: InterfaceOrientation, driver: FoldableDriver) async throws {
        let target = orientation.rotation
        let initial = try await driver.readDisplays()
        let startRotation = initial.activeDisplay?.currentRotation
        if startRotation == target {
            driver.log("Active display already at \(target.rawValue)")
            return
        }

        let search = try await searchRotation(target, from: initial, driver: driver)
        if search.matched {
            return
        }
        let current = search.state?.activeDisplay?.currentOrientation ?? "unknown"

        var restoreNote = ""
        if let startRotation {
            let restored = (try? await searchRotation(startRotation, from: search.state, driver: driver))?.matched ?? false
            restoreNote = restored
                ? " The display was returned to \(startRotation.rawValue)."
                : " The display could not be returned to \(startRotation.rawValue)."
        }
        let name = initial.activeDisplay?.name ?? ""
        throw CLIError(
            errorDescription: "The active display \(name) did not rotate to \(orientation.rawValue) (\(target.rawValue)); it reported \(current) after trying device orientations \(InterfaceOrientation.foldableSearchOrder.joined(separator: ", ")). The foreground app may not support that orientation.\(restoreNote)"
        )
    }

    /// Sets the device orientation with devicectl and checks the active display's rotation.
    ///
    /// Throws when the device does not take the orientation. Returns a warning when the device
    /// took it but the interface did not rotate, for example on a home screen that stays portrait.
    static func rotateSingleDisplay(
        to orientation: InterfaceOrientation,
        simulatorUDID: String,
        driver: FoldableDriver
    ) async throws -> String? {
        let value = orientation.deviceOrientation
        try await driver.setDeviceOrientation(value)

        let deadline = driver.now().addingTimeInterval(deviceOrientationTimeout)
        var reported: String?
        repeat {
            reported = try await driver.readDeviceOrientation()
            if reported == value {
                break
            }
            try await driver.sleep(0.25)
        } while driver.now() < deadline
        guard reported == value else {
            throw CLIError(
                errorDescription: "Simulator \(simulatorUDID) did not take device orientation \(value) for \(orientation.rawValue); devicectl reports \(reported ?? "unknown")."
            )
        }

        let result = try await waitForRotation(orientation.rotation, timeout: rotationTimeout, driver: driver)
        if result.matched {
            return nil
        }
        let current = result.state?.activeDisplay?.currentOrientation ?? "unknown"
        return "The device orientation is now \(value), but the active display still reports \(current) instead of \(orientation.rotation.rawValue) (\(orientation.rawValue)). The foreground app or screen may not support \(orientation.rawValue)."
    }
}

/// `xcrun devicectl device orientation get --json-output` payload.
struct DeviceOrientationEnvelope: Decodable {
    struct Result: Decodable {
        let deviceOrientation: String?
        let deviceOrientationNonFlat: String?
    }

    let result: Result?

    /// The non-flat orientation, falling back to the raw one.
    static func decode(from data: Data) throws -> String? {
        let envelope = try JSONDecoder().decode(DeviceOrientationEnvelope.self, from: data)
        return envelope.result?.deviceOrientationNonFlat ?? envelope.result?.deviceOrientation
    }
}
