import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Display Model

/// One display of a simulator as reported by `xcrun devicectl device info displays`.
///
/// Foldable simulators (iPhone Duo) expose two integrated displays: the cover display
/// (`primary`, display ID 1) and the inner display (display ID 3). Only devicectl reports
/// which one is `active`.
struct SimulatorDisplay: Decodable, Equatable {
    enum Rotation: String, Equatable {
        case rot0
        case rot90
        case rot180
        case rot270

        /// UI orientation of content shown with this rotation relative to the panel's native portrait axes.
        var simulatorOrientation: SimulatorOrientation {
            switch self {
            case .rot0:
                return .portrait
            case .rot90:
                return .landscape
            case .rot180:
                return .portraitUpsideDown
            case .rot270:
                return .landscapeFlipped
            }
        }
    }

    struct Size: Equatable {
        let width: Double
        let height: Double
    }

    let displayId: Int
    let name: String
    let uniqueId: String
    let primary: Bool
    /// `nil` when devicectl omits the flag, which it does on single-display devices.
    let active: Bool?
    let backlightState: String?
    let currentOrientation: String?
    let nativeOrientation: String?
    let nativeSize: Size?
    let pointScale: Double?
    let bounds: Size?
    let isIntegrated: Bool

    var currentRotation: Rotation? {
        currentOrientation.flatMap(Rotation.init(rawValue:))
    }

    /// Native (portrait) panel size in points: `nativeSize / pointScale`.
    var nativeSizePoints: Size? {
        guard let nativeSize, let pointScale, pointScale > 0 else {
            return nil
        }
        return Size(width: nativeSize.width / pointScale, height: nativeSize.height / pointScale)
    }

    var isBacklightOff: Bool {
        backlightState == "off"
    }

    init(
        displayId: Int,
        name: String,
        uniqueId: String,
        primary: Bool,
        active: Bool?,
        backlightState: String?,
        currentOrientation: String?,
        nativeOrientation: String? = "rot0",
        nativeSize: Size?,
        pointScale: Double?,
        bounds: Size? = nil,
        isIntegrated: Bool = true
    ) {
        self.displayId = displayId
        self.name = name
        self.uniqueId = uniqueId
        self.primary = primary
        self.active = active
        self.backlightState = backlightState
        self.currentOrientation = currentOrientation
        self.nativeOrientation = nativeOrientation
        self.nativeSize = nativeSize
        self.pointScale = pointScale
        self.bounds = bounds
        self.isIntegrated = isIntegrated
    }

    private enum CodingKeys: String, CodingKey {
        case displayId
        case name
        case uniqueId
        case primary
        case active
        case backlightState
        case currentOrientation
        case nativeOrientation
        case nativeSize
        case pointScale
        case bounds
        case type
    }

    private enum DisplayTypeKeys: String, CodingKey {
        case integrated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Display selection and the touch guard need these fields; they are decoded strictly.
        displayId = try container.decode(Int.self, forKey: .displayId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        uniqueId = try container.decodeIfPresent(String.self, forKey: .uniqueId) ?? ""
        primary = try container.decodeIfPresent(Bool.self, forKey: .primary) ?? false
        active = try container.decodeIfPresent(Bool.self, forKey: .active)
        backlightState = try container.decodeIfPresent(String.self, forKey: .backlightState)

        // Orientation and geometry are only used for coordinate mapping. A shape change in a later
        // devicectl JSON version leaves them nil instead of failing the whole decode.
        currentOrientation = (try? container.decodeIfPresent(String.self, forKey: .currentOrientation)) ?? nil
        nativeOrientation = (try? container.decodeIfPresent(String.self, forKey: .nativeOrientation)) ?? nil
        pointScale = (try? container.decodeIfPresent(Double.self, forKey: .pointScale)) ?? nil
        let nativeValues = (try? container.decodeIfPresent([Double].self, forKey: .nativeSize)) ?? nil
        nativeSize = nativeValues.flatMap(Self.size(from:))
        // `bounds` is `[[originX, originY], [width, height]]`.
        let boundsValues = (try? container.decodeIfPresent([[Double]].self, forKey: .bounds)) ?? nil
        bounds = boundsValues.flatMap { $0.count == 2 ? Self.size(from: $0[1]) : nil }

        if container.contains(.type) {
            let typeContainer = try container.nestedContainer(keyedBy: DisplayTypeKeys.self, forKey: .type)
            isIntegrated = typeContainer.contains(.integrated)
        } else {
            isIntegrated = false
        }
    }

    private static func size(from values: [Double]) -> Size? {
        guard values.count == 2 else { return nil }
        return Size(width: values[0], height: values[1])
    }
}

// MARK: - Display State

/// Integrated displays of one simulator plus the device orientation, decoded from devicectl.
struct SimulatorDisplayState: Equatable {
    static let supportedJSONVersion = 5

    let displays: [SimulatorDisplay]
    let deviceOrientation: String?
    let jsonVersion: Int?

    init(displays: [SimulatorDisplay], deviceOrientation: String? = nil, jsonVersion: Int? = supportedJSONVersion) {
        self.displays = displays.filter(\.isIntegrated)
        self.deviceOrientation = deviceOrientation
        self.jsonVersion = jsonVersion
    }

    var isMultiDisplay: Bool {
        displays.count > 1
    }

    /// The display currently showing UI.
    ///
    /// Selection: the display flagged `active`; a single integrated display (devicectl omits
    /// `active` there); the display whose backlight is `activeOn`. `nil` when none applies.
    var activeDisplay: SimulatorDisplay? {
        if let flagged = displays.first(where: { $0.active == true }) {
            return flagged
        }
        if displays.count == 1 {
            return displays[0]
        }
        let lit = displays.filter { $0.backlightState == "activeOn" }
        return lit.count == 1 ? lit[0] : nil
    }

    /// The cover display of a foldable: the primary integrated display.
    var coverDisplay: SimulatorDisplay? {
        guard isMultiDisplay else { return nil }
        return displays.first(where: \.primary)
    }

    /// The inner display of a foldable: the first non-primary integrated display.
    var innerDisplay: SimulatorDisplay? {
        guard isMultiDisplay else { return nil }
        return displays.first(where: { !$0.primary })
    }

    /// Decodes the `--json-output` payload of `xcrun devicectl device info displays`.
    static func decode(from data: Data) throws -> SimulatorDisplayState {
        let envelope = try JSONDecoder().decode(DeviceCtlDisplaysEnvelope.self, from: data)
        if let outcome = envelope.info?.outcome, outcome != "success" {
            let detail = envelope.error?.localizedDescription.map { ": \($0)" } ?? "."
            throw CLIError(errorDescription: "devicectl reported outcome '\(outcome)' while reading simulator displays\(detail)")
        }
        guard let result = envelope.result else {
            throw CLIError(errorDescription: "devicectl returned no display information.")
        }
        return SimulatorDisplayState(
            displays: result.displays,
            deviceOrientation: result.orientation?.currentDeviceOrientation,
            jsonVersion: envelope.info?.jsonVersion
        )
    }
}

/// The `error` object devicectl writes into its JSON envelope on failure.
struct DeviceCtlErrorPayload: Decodable {
    private struct StringValue: Decodable {
        let string: String?
    }

    private struct UserInfo: Decodable {
        let localizedDescription: StringValue?

        enum CodingKeys: String, CodingKey {
            case localizedDescription = "NSLocalizedDescription"
        }
    }

    private let userInfo: UserInfo?

    var localizedDescription: String? {
        userInfo?.localizedDescription?.string
    }
}

private struct DeviceCtlDisplaysEnvelope: Decodable {
    struct Info: Decodable {
        let outcome: String?
        let jsonVersion: Int?
    }

    struct Result: Decodable {
        struct Orientation: Decodable {
            let currentDeviceOrientation: String?
        }

        let displays: [SimulatorDisplay]
        let orientation: Orientation?
    }

    let info: Info?
    let result: Result?
    let error: DeviceCtlErrorPayload?
}

// MARK: - Display Selection

/// Value of the `--display` option.
enum DisplaySelection: Equatable {
    /// The active display on a foldable; the default capture path elsewhere.
    case auto
    /// The cover (primary) display of a foldable.
    case cover
    /// The inner (non-primary) display of a foldable.
    case inner
    /// A devicectl / simctl display ID.
    case id(Int)
    /// A display name (for example `LCD-1`) or unique ID.
    case name(String)

    init?(argument: String) {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "auto":
            self = .auto
        case "cover":
            self = .cover
        case "inner":
            self = .inner
        default:
            if let identifier = Int(trimmed) {
                guard identifier >= 0 else { return nil }
                self = .id(identifier)
            } else {
                self = .name(trimmed)
            }
        }
    }

    /// Resolves the selection against devicectl state.
    func resolve(in state: SimulatorDisplayState) throws -> SimulatorDisplay {
        switch self {
        case .auto:
            guard let display = state.activeDisplay else {
                throw CLIError(errorDescription: "AXe could not determine the active simulator display. Pass --display cover, --display inner, or a display ID.")
            }
            return display
        case .cover:
            guard let display = state.coverDisplay else {
                throw CLIError(errorDescription: "--display cover requires a foldable simulator with a cover display.")
            }
            return display
        case .inner:
            guard let display = state.innerDisplay else {
                throw CLIError(errorDescription: "--display inner requires a foldable simulator with an inner display.")
            }
            return display
        case .id(let identifier):
            guard let display = state.displays.first(where: { $0.displayId == identifier }) else {
                throw unknownDisplayError(String(identifier), state: state)
            }
            return display
        case .name(let name):
            let match = state.displays.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    || $0.uniqueId.caseInsensitiveCompare(name) == .orderedSame
            }
            guard let display = match else {
                throw unknownDisplayError(name, state: state)
            }
            return display
        }
    }

    private func unknownDisplayError(_ value: String, state: SimulatorDisplayState) -> CLIError {
        let available = state.displays
            .map { "\($0.displayId) (\($0.name))" }
            .joined(separator: ", ")
        return CLIError(errorDescription: "No simulator display matches '\(value)'. Available displays: \(available).")
    }
}

/// How `axe screenshot` captures the requested display.
enum ScreenshotCapture: Equatable {
    /// `FBSimulator.takeScreenshot` (the first framebuffer), the pre-foldable behaviour.
    case framebuffer
    /// simctl with a caller-supplied `--display` value that was not validated against devicectl.
    case unvalidatedDisplay(String)
    /// simctl with a display resolved from devicectl state.
    case display(SimulatorDisplay)

    /// Decides the capture path.
    ///
    /// - Parameters:
    ///   - state: devicectl state, or `nil` when the display probe does not apply.
    ///   - isFoldableWithProbeDisabled: the simulator is foldable but `AXE_DISPLAY_PROBE=never`.
    static func resolve(
        selection: DisplaySelection,
        state: SimulatorDisplayState?,
        isFoldableWithProbeDisabled: Bool = false
    ) throws -> ScreenshotCapture {
        guard let state else {
            switch selection {
            case .auto:
                return .framebuffer
            case .cover, .inner:
                if isFoldableWithProbeDisabled {
                    throw CLIError(
                        errorDescription: "--display cover and --display inner need display detection, which \(DisplayProbePolicy.environmentKey)=never disables. Unset it, or pass a display ID or name."
                    )
                }
                throw CLIError(errorDescription: "--display cover and --display inner require a foldable simulator.")
            case .id(let identifier):
                return .unvalidatedDisplay(String(identifier))
            case .name(let name):
                return .unvalidatedDisplay(name)
            }
        }
        guard state.isMultiDisplay || selection != .auto else {
            return .framebuffer
        }
        return .display(try selection.resolve(in: state))
    }
}

// MARK: - Probe Policy

/// Controls when AXe runs devicectl to read display state (`AXE_DISPLAY_PROBE`).
enum DisplayProbePolicy: String, Codable {
    /// Probe foldable device types only (default).
    case auto
    /// Probe every simulator.
    case always
    /// Never probe; keep the single-display behaviour.
    case never

    static let environmentKey = "AXE_DISPLAY_PROBE"

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> DisplayProbePolicy {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return .auto
        }
        return DisplayProbePolicy(rawValue: raw) ?? .auto
    }

    func shouldProbe(deviceTypeIdentifier: String?) -> Bool {
        switch self {
        case .always:
            return true
        case .never:
            return false
        case .auto:
            return deviceTypeIdentifier.map(SimulatorDisplays.isFoldableDeviceType) ?? false
        }
    }
}

// MARK: - Interim Touch Guard

/// Blocks touch input that cannot reach the active display.
///
/// AXe dispatches touches through `FBSimulatorHID`, which only reaches the primary (cover)
/// touchscreen. On an unfolded foldable the inner display is active, and touches would report
/// success without any effect. Until inner-display routing exists, such touches fail.
enum FoldableTouchGuard {
    static let innerDisplayMessage = "AXe cannot deliver touches to the inner display of a foldable simulator yet. Fold the simulator with `axe hinge close` so the cover display is active, or wait for inner-display support."
    static let unknownDisplayMessage = "AXe could not determine which display of the foldable simulator is active, so no touch was sent. Confirm the simulator is booted and try again."

    /// Returns the reason touches must not be sent, or `nil` when they can be delivered.
    static func blockReason(for state: SimulatorDisplayState?) -> String? {
        guard let state, state.isMultiDisplay else {
            return nil
        }
        guard let active = state.activeDisplay else {
            return unknownDisplayMessage
        }
        return active.primary ? nil : innerDisplayMessage
    }

    @MainActor
    static func enforce(for simulator: FBSimulator, logger: AxeLogger) async throws {
        let state = try await SimulatorDisplays.state(for: simulator, logger: logger)
        if let reason = blockReason(for: state) {
            logger.error().log("Touch blocked: \(reason)")
            throw CLIError(errorDescription: reason)
        }
    }
}

extension FBSimulatorHIDEvent {
    /// True when the event, or any nested event, sends digitizer input.
    ///
    /// Unknown future cases count as touch so a new digitizer event cannot bypass the guard.
    var producesTouch: Bool {
        switch self {
        case .touch, .twoFingerTouch:
            return true
        case .composite(let events):
            return events.contains { $0.producesTouch }
        case .button, .keyboard, .delay, .deviceOrientation, .shake, .toggleInCallStatusBar, .lockDevice:
            return false
        @unknown default:
            return true
        }
    }
}

// MARK: - Reader

/// Reads simulator display state from devicectl, only for simulators that need it.
///
/// Non-foldable simulators never pay the devicectl cost (about 0.2 s) unless
/// `AXE_DISPLAY_PROBE=always` is set. Results are cached until `invalidateCachedState()`;
/// the HID broker calls it per request and `axe batch` per step.
@MainActor
enum SimulatorDisplays {
    nonisolated static let foldableDeviceTypeMarker = "iPhone-Duo"
    nonisolated static let devicectlTimeout: TimeInterval = 10
    nonisolated static let screenshotTimeout: TimeInterval = 10

    /// Policy supplied by a client process. The hid-broker sets it per request so a long-lived
    /// broker follows the `AXE_DISPLAY_PROBE` value of the command it serves, not its own.
    static var policyOverride: DisplayProbePolicy?

    private static var deviceTypeIdentifiers: [String: String] = [:]
    private static var cachedStates: [String: SimulatorDisplayState] = [:]

    static var policy: DisplayProbePolicy {
        policyOverride ?? DisplayProbePolicy.current()
    }

    nonisolated static func isFoldableDeviceType(_ identifier: String) -> Bool {
        identifier.contains(foldableDeviceTypeMarker)
    }

    static func invalidateCachedState() {
        cachedStates.removeAll()
    }

    static func cachedState(forSimulatorUDID simulatorUDID: String) -> SimulatorDisplayState? {
        cachedStates[simulatorUDID]
    }

    /// Seeds the cache. Used by tests to exercise invalidation without a simulator.
    static func cacheState(_ state: SimulatorDisplayState, forSimulatorUDID simulatorUDID: String) {
        cachedStates[simulatorUDID] = state
    }

    /// Records the device type of a simulator that a caller already looked up, so later UDID-only
    /// lookups do not create another simulator set.
    @discardableResult
    static func recordDeviceType(for simulator: FBSimulator) -> String? {
        if let cached = deviceTypeIdentifiers[simulator.udid] {
            return cached
        }
        let identifier: String? = simulator.device.deviceTypeIdentifier
        if let identifier {
            deviceTypeIdentifiers[simulator.udid] = identifier
        }
        return identifier
    }

    static func isFoldable(_ simulator: FBSimulator) -> Bool {
        recordDeviceType(for: simulator).map(isFoldableDeviceType) ?? false
    }

    /// Display state for display-aware simulators; `nil` when the probe does not apply.
    static func state(for simulator: FBSimulator, logger: AxeLogger) async throws -> SimulatorDisplayState? {
        try await state(
            simulatorUDID: simulator.udid,
            deviceTypeIdentifier: recordDeviceType(for: simulator),
            logger: logger
        )
    }

    /// Display state looked up by UDID; `nil` for unknown simulators or when the probe does not apply.
    ///
    /// A failed simulator lookup is logged and treated as "no display state", like
    /// `SimulatorOrientationReader`, so non-foldables gain no failure mode. devicectl failures on a
    /// foldable still throw.
    static func state(forSimulatorUDID simulatorUDID: String, logger: AxeLogger) async throws -> SimulatorDisplayState? {
        guard policy != .never else {
            return nil
        }
        if let knownDeviceType = deviceTypeIdentifiers[simulatorUDID] {
            return try await state(simulatorUDID: simulatorUDID, deviceTypeIdentifier: knownDeviceType, logger: logger)
        }
        let simulatorSet: FBSimulatorSet
        do {
            simulatorSet = try await getSimulatorSet(
                deviceSetPath: nil,
                logger: logger,
                reporter: EmptyEventReporter.shared
            )
        } catch {
            logger.info().log("Display probe: simulator set unavailable: \(error.localizedDescription)")
            return nil
        }
        guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            logger.info().log("Display probe: simulator \(simulatorUDID) not found")
            return nil
        }
        return try await state(for: simulator, logger: logger)
    }

    private static func state(
        simulatorUDID: String,
        deviceTypeIdentifier: String?,
        logger: AxeLogger
    ) async throws -> SimulatorDisplayState? {
        guard policy.shouldProbe(deviceTypeIdentifier: deviceTypeIdentifier) else {
            return nil
        }
        if let cached = cachedStates[simulatorUDID] {
            return cached
        }
        let state = try await read(simulatorUDID: simulatorUDID, logger: logger)
        cachedStates[simulatorUDID] = state
        return state
    }

    /// Runs `xcrun devicectl device info displays` and decodes the result.
    static func read(simulatorUDID: String, logger: AxeLogger) async throws -> SimulatorDisplayState {
        logger.info().log("Reading display state with devicectl for \(simulatorUDID)")
        let result: ProcessResult
        do {
            result = try await XcrunProcess.run(
                ["devicectl", "device", "info", "displays", "-d", simulatorUDID, "-q", "-j", "-"],
                timeout: devicectlTimeout
            )
        } catch {
            throw devicectlError(simulatorUDID: simulatorUDID, detail: error.localizedDescription)
        }
        guard result.status == 0 else {
            throw devicectlError(simulatorUDID: simulatorUDID, detail: result.failureDetail)
        }
        do {
            let state = try SimulatorDisplayState.decode(from: result.standardOutput)
            if let version = state.jsonVersion, version != SimulatorDisplayState.supportedJSONVersion {
                logger.info().log("devicectl jsonVersion \(version) differs from the tested version \(SimulatorDisplayState.supportedJSONVersion)")
            }
            let summary = state.displays
                .map { "\($0.displayId)/\($0.name) active=\($0.active.map(String.init) ?? "nil") primary=\($0.primary) \($0.currentOrientation ?? "?")" }
                .joined(separator: ", ")
            logger.info().log("Display state: \(summary)")
            return state
        } catch {
            throw devicectlError(simulatorUDID: simulatorUDID, detail: error.localizedDescription)
        }
    }

    private static func devicectlError(simulatorUDID: String, detail: String) -> CLIError {
        let suffix = detail.isEmpty ? "" : " (\(detail))"
        return CLIError(
            errorDescription: "AXe could not read the displays of simulator \(simulatorUDID) with `xcrun devicectl device info displays`\(suffix). Foldable simulators require Xcode 27.1 or later. Set AXE_DISPLAY_PROBE=never to skip display detection."
        )
    }

    /// Resolves the display to capture for a screenshot.
    ///
    /// Returns `nil` when the default framebuffer capture applies (single display, `auto`).
    /// Returns the simctl `--display` argument otherwise.
    static func screenshotDisplayArgument(
        selection: DisplaySelection,
        simulator: FBSimulator,
        logger: AxeLogger
    ) async throws -> String? {
        let state = try await state(for: simulator, logger: logger)
        let capture = try ScreenshotCapture.resolve(
            selection: selection,
            state: state,
            isFoldableWithProbeDisabled: state == nil && policy == .never && isFoldable(simulator)
        )
        switch capture {
        case .framebuffer:
            return nil
        case .unvalidatedDisplay(let argument):
            return argument
        case .display(var display):
            if selection == .auto, display.isBacklightOff {
                display = await waitForBacklight(of: display, simulator: simulator, logger: logger)
            }
            logger.info().log("Capturing display \(display.displayId) (\(display.name))")
            return String(display.displayId)
        }
    }

    /// The active flag can lead the backlight after a fold; waits up to 2 s for the active panel to
    /// light. Any failure while refreshing keeps the last resolved display and ends in a warning.
    private static func waitForBacklight(
        of initial: SimulatorDisplay,
        simulator: FBSimulator,
        logger: AxeLogger
    ) async -> SimulatorDisplay {
        var display = initial
        let deadline = Date().addingTimeInterval(2)
        while display.isBacklightOff, Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(250))
                invalidateCachedState()
                guard let refreshed = try await state(for: simulator, logger: logger) else { break }
                display = try DisplaySelection.auto.resolve(in: refreshed)
            } catch {
                logger.info().log("Backlight wait: \(error.localizedDescription)")
                break
            }
        }
        if display.isBacklightOff {
            print("Warning: display \(display.displayId) (\(display.name)) is active but its backlight is off; the screenshot may be black.", to: &standardError)
        }
        return display
    }

    /// Captures one display with `xcrun simctl io <udid> screenshot --display=<display>`.
    static func captureScreenshot(
        simulatorUDID: String,
        display: String,
        to outputURL: URL,
        timeout: TimeInterval = screenshotTimeout
    ) async throws {
        let result = try await XcrunProcess.run(
            ["simctl", "io", simulatorUDID, "screenshot", "--type=png", "--display=\(display)", outputURL.path],
            timeout: timeout
        )
        guard result.status == 0 else {
            let detail = result.failureDetail
            throw CLIError(
                errorDescription: "AXe could not capture display \(display) of simulator \(simulatorUDID)" + (detail.isEmpty ? "." : ": \(detail)")
            )
        }
    }
}
