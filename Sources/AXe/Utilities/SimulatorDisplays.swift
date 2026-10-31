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

    /// `displayId` of a display whose devicectl ID could not be read.
    static let unknownDisplayID = -1

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

    /// False when devicectl's numeric ID could not be read (`unknownDisplayID`).
    var hasKnownDisplayID: Bool {
        displayId != Self.unknownDisplayID
    }

    /// True when both describe the same display: by unique ID when both have one (IDB always
    /// reports it), otherwise by display ID. Displays whose IDs are unknown never match by ID alone.
    func isSameDisplay(as other: SimulatorDisplay) -> Bool {
        if !uniqueId.isEmpty, !other.uniqueId.isEmpty {
            return uniqueId == other.uniqueId
        }
        return hasKnownDisplayID && displayId == other.displayId
    }

    /// `3 (LCD-1)` for messages; the name and unique ID when the numeric ID is unknown.
    var label: String {
        if hasKnownDisplayID {
            return "\(displayId) (\(name))"
        }
        return uniqueId.isEmpty ? name : "\(name) (\(uniqueId))"
    }

    /// A `--display` value that selects this display: its numeric ID, or its name (or unique ID)
    /// when the numeric ID is unknown.
    var selectionArgument: String {
        if hasKnownDisplayID {
            return String(displayId)
        }
        return name.isEmpty ? uniqueId : name
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
        // Display selection and touch routing need these fields; they are decoded strictly.
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

/// Integrated displays of one simulator plus the device orientation.
///
/// A simulator that reports displays but no integrated one keeps its sole primary display, as IDB
/// targets it: an Apple TV's only display is its external `TVOut`.
///
/// Built from IDB's display configuration (`Simulator.displays.configuration()`, read in process)
/// for touch routing, describe-ui and captures, or decoded from devicectl for `axe posture`, which
/// also prints the backlight and the device orientation.
struct SimulatorDisplayState: Equatable {
    static let supportedJSONVersion = 5

    let displays: [SimulatorDisplay]
    let deviceOrientation: String?
    let jsonVersion: Int?

    init(displays: [SimulatorDisplay], deviceOrientation: String? = nil, jsonVersion: Int? = supportedJSONVersion) {
        self.displays = Self.interactionDisplays(displays)
        self.deviceOrientation = deviceOrientation
        self.jsonVersion = jsonVersion
    }

    /// The integrated displays; without any, the sole primary display (an Apple TV's external
    /// TVOut), as IDB targets it; otherwise none.
    static func interactionDisplays(_ displays: [SimulatorDisplay]) -> [SimulatorDisplay] {
        let integrated = displays.filter(\.isIntegrated)
        guard integrated.isEmpty else { return integrated }
        let primary = displays.filter(\.primary)
        return primary.count == 1 ? primary : []
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

    /// The integrated displays of IDB's display configuration.
    ///
    /// IDB reads the same CoreDevice report as devicectl but does not expose devicectl's numeric
    /// display IDs (1 cover, 3 inner), so they come from `displayIDs`, keyed by unique ID; a display
    /// missing there gets `unknownDisplayID`. IDB reports activity, not the backlight, so
    /// `backlightState` is `nil`; an `unknown` activity leaves `active` `nil`.
    ///
    /// A runtime that does not identify its displays reports no displays and only the geometry of
    /// its sole integrated display (`.unidentified`); that display is kept, without IDs or a name.
    init(configuration: FBSimulatorControl.SimulatorDisplayConfiguration, displayIDs: [String: Int]) {
        // `init(displays:)` keeps the integrated displays, or a sole primary external one.
        let displays = configuration.displays.map { display in
            let size = SimulatorDisplay.Size(width: Double(display.bounds.width), height: Double(display.bounds.height))
            let active: Bool?
            switch display.activity {
            case .active:
                active = true
            case .inactive:
                active = false
            case .unknown:
                active = nil
            @unknown default:
                active = nil
            }
            return SimulatorDisplay(
                displayId: displayIDs[display.uniqueID] ?? SimulatorDisplay.unknownDisplayID,
                name: display.name,
                uniqueId: display.uniqueID,
                primary: display.isPrimary,
                active: active,
                backlightState: nil,
                currentOrientation: display.rotation.rawValue,
                nativeSize: size,
                pointScale: display.scale,
                bounds: size,
                isIntegrated: display.isIntegrated
            )
        }
        var unidentified: SimulatorDisplay?
        if case .unidentified(let geometry) = configuration.active {
            unidentified = Self.unidentifiedDisplay(
                rotation: geometry.rotation.rawValue,
                pixelSize: SimulatorDisplay.Size(width: Double(geometry.bounds.width), height: Double(geometry.bounds.height)),
                scale: geometry.scale
            )
        }
        self.init(idbDisplays: displays, unidentifiedDisplay: unidentified)
    }

    /// The displays IDB identified, or the sole unidentified display when it identified none.
    init(idbDisplays: [SimulatorDisplay], unidentifiedDisplay: SimulatorDisplay?) {
        if idbDisplays.isEmpty, let unidentifiedDisplay {
            self.init(displays: [unidentifiedDisplay])
            return
        }
        // IDB sorts displays by unique ID; devicectl lists the primary (cover) display first.
        self.init(displays: idbDisplays.sorted {
            ($0.primary ? 0 : 1, $0.displayId, $0.uniqueId) < ($1.primary ? 0 : 1, $1.displayId, $1.uniqueId)
        })
    }

    /// The sole integrated display of a runtime that does not identify its displays: primary and
    /// active, with IDB's geometry and no ID, name or unique ID.
    static func unidentifiedDisplay(rotation: String, pixelSize: SimulatorDisplay.Size, scale: Double) -> SimulatorDisplay {
        SimulatorDisplay(
            displayId: SimulatorDisplay.unknownDisplayID,
            name: "",
            uniqueId: "",
            primary: true,
            active: true,
            backlightState: nil,
            currentOrientation: rotation,
            nativeSize: pixelSize,
            pointScale: scale,
            bounds: pixelSize
        )
    }

    /// This devicectl state with the activity, rotation and geometry IDB reports for the same
    /// displays (matched by unique ID). devicectl keeps the display IDs, the backlight and the
    /// device orientation, which IDB does not report.
    func overlaying(_ configuration: SimulatorDisplayState) -> SimulatorDisplayState {
        let reported = Dictionary(configuration.displays.map { ($0.uniqueId, $0) }, uniquingKeysWith: { first, _ in first })
        let merged = displays.map { display -> SimulatorDisplay in
            guard let idb = reported[display.uniqueId] else { return display }
            return SimulatorDisplay(
                displayId: display.displayId,
                name: display.name,
                uniqueId: display.uniqueId,
                primary: display.primary,
                active: idb.active ?? display.active,
                backlightState: display.backlightState,
                currentOrientation: idb.currentOrientation ?? display.currentOrientation,
                nativeOrientation: display.nativeOrientation,
                nativeSize: idb.nativeSize ?? display.nativeSize,
                pointScale: idb.pointScale ?? display.pointScale,
                bounds: display.bounds,
                isIntegrated: display.isIntegrated
            )
        }
        return SimulatorDisplayState(displays: merged, deviceOrientation: deviceOrientation, jsonVersion: jsonVersion)
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
        let available = state.displays.map(\.label).joined(separator: ", ")
        if case .id = self, state.displays.contains(where: { !$0.hasKnownDisplayID }) {
            return CLIError(
                errorDescription: "No simulator display matches '\(value)': AXe could not read the numeric display IDs (`xcrun devicectl device info displays` failed). Select the display by name or unique ID, or with --display cover or --display inner. Available displays: \(available)."
            )
        }
        return CLIError(errorDescription: "No simulator display matches '\(value)'. Available displays: \(available).")
    }
}

/// How `axe screenshot` and `axe record-video` capture the requested display.
enum DisplayCapture: Equatable {
    /// The idb screenshot of the active display (`Simulator.screenshot.take`), the pre-foldable
    /// behaviour. Used only for single-display simulators.
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
    ) throws -> DisplayCapture {
        guard let state else {
            switch selection {
            case .auto:
                return .framebuffer
            case .cover, .inner:
                throw coverInnerWithoutStateError(isFoldableWithProbeDisabled: isFoldableWithProbeDisabled)
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

    /// Warning for an explicitly selected display that is not showing UI; `nil` for `auto` (which
    /// waits for the backlight instead) and for an active, lit display.
    static func inactiveDisplayWarning(for display: SimulatorDisplay, selection: DisplaySelection) -> String? {
        guard selection != .auto else { return nil }
        let reason: String
        if display.active == false {
            reason = "is not active"
        } else if display.isBacklightOff {
            reason = "has its backlight off"
        } else {
            return nil
        }
        return "Warning: display \(display.label) \(reason); the capture may be black."
    }

    /// Error for `--display cover|inner` when no display state is available.
    static func coverInnerWithoutStateError(isFoldableWithProbeDisabled: Bool) -> CLIError {
        if isFoldableWithProbeDisabled {
            return CLIError(
                errorDescription: "--display cover and --display inner need display detection, which \(DisplayProbePolicy.environmentKey)=never disables. Unset it, or pass a display ID or name."
            )
        }
        return CLIError(errorDescription: "--display cover and --display inner require a foldable simulator.")
    }
}

/// Which displays `axe stream-video` can stream.
///
/// IDB streams the active display (`VideoStreamConfiguration(display: .active)` and
/// `screenshot.take(.active)`): the cover while a foldable is folded, the inner display while it is
/// unfolded. An explicit `--display` is accepted when it names that display and refused otherwise.
enum StreamCapture {
    /// Throws unless `selection` names the active display (or is `auto`).
    ///
    /// - Parameters:
    ///   - state: devicectl state, or `nil` when the display probe does not apply.
    ///   - isFoldableWithProbeDisabled: the simulator is foldable but `AXE_DISPLAY_PROBE=never`.
    static func validate(
        selection: DisplaySelection,
        state: SimulatorDisplayState?,
        isFoldableWithProbeDisabled: Bool = false
    ) throws {
        guard let state else {
            switch selection {
            case .auto:
                return
            case .cover, .inner:
                throw DisplayCapture.coverInnerWithoutStateError(isFoldableWithProbeDisabled: isFoldableWithProbeDisabled)
            case .id, .name:
                throw CLIError(
                    errorDescription: "stream-video cannot check display '\(selection.defaultValueDescription)' without display detection; it streams the active display. Omit --display, or set \(DisplayProbePolicy.environmentKey)=always."
                )
            }
        }
        guard selection != .auto else { return }
        let display = try selection.resolve(in: state)
        guard state.isMultiDisplay else { return }
        guard let active = state.activeDisplay else {
            throw CLIError(
                errorDescription: "AXe could not determine the active simulator display, and stream-video streams only the active display. Omit --display to stream whichever display is active."
            )
        }
        guard display.isSameDisplay(as: active) else {
            throw CLIError(
                errorDescription: "stream-video streams the active display, and display \(display.label) is not active (display \(active.label) is). Fold or unfold the simulator with `axe hinge`, omit --display, or use `axe record-video --display \(display.selectionArgument)` or `axe screenshot --display \(display.selectionArgument)`."
            )
        }
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

// MARK: - Reader

/// Reads simulator display state, only for simulators that need it.
///
/// The state comes from IDB's display configuration, read in process once any fold or rotation
/// has settled. Only devicectl knows the numeric display IDs (1 cover, 3 inner) that AXe prints
/// and accepts in `--display`; they are read with devicectl once per set of displays and kept in
/// `DisplayIDCache` (a failed read is not repeated in the same process, and hinge and rotation
/// polling never runs devicectl). `axe posture` still reads devicectl every time, for the backlight and device
/// orientation. Non-foldable simulators are not probed unless `AXE_DISPLAY_PROBE=always` is set.
/// Results are cached until `invalidateCachedState()`; the HID broker calls it per request and
/// `axe batch` per step.
@MainActor
enum SimulatorDisplays {
    nonisolated static let foldableDeviceTypeMarker = "iPhone-Duo"
    nonisolated static let devicectlTimeout: TimeInterval = 10
    // simctl writes the PNG within about a second but can take over 10 s to exit on a loaded host.
    nonisolated static let screenshotTimeout: TimeInterval = 30

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
    static func recordDeviceType(for simulator: Simulator) -> String? {
        if let cached = deviceTypeIdentifiers[simulator.udid] {
            return cached
        }
        let identifier: String? = simulator.configuration.deviceTypeIdentifier
        if let identifier {
            deviceTypeIdentifiers[simulator.udid] = identifier
        }
        return identifier
    }

    static func isFoldable(_ simulator: Simulator) -> Bool {
        recordDeviceType(for: simulator).map(isFoldableDeviceType) ?? false
    }

    nonisolated static let probeDisabledWarning = "Warning: \(DisplayProbePolicy.environmentKey)=never disables display detection on this foldable simulator. Touches still reach the active display, but selector taps (--id, --label, --value), slider, gesture presets and describe-ui are not display-aware: while the inner display is active, home-screen (SpringBoard) frames stay in the panel's native portrait points, so selector taps there can land in the wrong place, and points outside the display are not refused."

    private static var didWarnProbeDisabled = false

    /// Prints `probeDisabledWarning` once per process when the probe is disabled on a foldable.
    static func warnIfProbeDisabled(simulatorUDID: String, logger: AxeLogger) {
        guard !didWarnProbeDisabled, policy == .never else { return }
        var deviceType = deviceTypeIdentifiers[simulatorUDID]
        if deviceType == nil, let simulator = try? SimulatorSession.simulator(udid: simulatorUDID, logger: logger) {
            deviceType = recordDeviceType(for: simulator)
        }
        guard let deviceType, isFoldableDeviceType(deviceType) else { return }
        didWarnProbeDisabled = true
        print(probeDisabledWarning, to: &standardError)
    }

    /// Display state for display-aware simulators; `nil` when the probe does not apply.
    static func state(for simulator: Simulator, logger: AxeLogger) async throws -> SimulatorDisplayState? {
        guard policy.shouldProbe(deviceTypeIdentifier: recordDeviceType(for: simulator)) else {
            return nil
        }
        if let cached = cachedStates[simulator.udid] {
            return cached
        }
        let state = try await readConfiguration(of: simulator, logger: logger)
        cachedStates[simulator.udid] = state
        return state
    }

    /// Display state looked up by UDID; `nil` for unknown simulators or when the probe does not apply.
    ///
    /// A failed simulator lookup is logged and treated as "no display state", so non-foldables
    /// gain no failure mode. Display read failures on a foldable still throw.
    static func state(forSimulatorUDID simulatorUDID: String, logger: AxeLogger) async throws -> SimulatorDisplayState? {
        guard policy != .never else {
            return nil
        }
        if let knownDeviceType = deviceTypeIdentifiers[simulatorUDID],
           !policy.shouldProbe(deviceTypeIdentifier: knownDeviceType) {
            return nil
        }
        let found: Simulator?
        do {
            found = try SimulatorSession.simulator(udid: simulatorUDID, logger: logger)
        } catch {
            logger.info().log("Display probe: simulator set unavailable: \(error.localizedDescription)")
            return nil
        }
        guard let simulator = found else {
            logger.info().log("Display probe: simulator \(simulatorUDID) not found")
            return nil
        }
        return try await state(for: simulator, logger: logger)
    }

    /// How long a display read waits for a fold, unfold or rotation to settle. IDB polls within
    /// this budget; a hinge change has been seen to take about 4 s on a heavily loaded host.
    nonisolated static let settleBudget: TimeInterval = 10

    /// IDB's display configuration once any transition has settled, without the cache.
    ///
    /// - Parameters:
    ///   - settleBudget: how long IDB may wait for a transition to settle. A configuration still
    ///     changing after that throws `DisplaysStillChangingError`; it is never returned or cached.
    ///   - lookUpDisplayIDs: read devicectl's numeric IDs when `DisplayIDCache` lacks them. Polling
    ///     loops pass `false` and use only the cache, so devicectl never runs inside them.
    static func readConfiguration(
        of simulator: Simulator,
        logger: AxeLogger,
        settleBudget: TimeInterval = settleBudget,
        lookUpDisplayIDs: Bool = true
    ) async throws -> SimulatorDisplayState {
        let configuration = try await settledConfiguration(of: simulator, within: settleBudget, logger: logger)
        let needed = Set(configuration.displays.filter(\.isIntegrated).map(\.uniqueID))
        let ids = lookUpDisplayIDs
            ? await displayIDs(needed: needed, simulatorUDID: simulator.udid, logger: logger)
            : DisplayIDCache.ids(forSimulatorUDID: simulator.udid) ?? [:]
        let state = SimulatorDisplayState(configuration: configuration, displayIDs: ids)
        logger.info().log("Display state (IDB): \(summary(of: state))")
        return state
    }

    /// IDB's configuration once settled within `budget`; throws `DisplaysStillChangingError` when
    /// it is still changing then.
    static func settledConfiguration(
        of simulator: Simulator,
        within budget: TimeInterval,
        logger: AxeLogger
    ) async throws -> FBSimulatorControl.SimulatorDisplayConfiguration {
        let configuration = try await configuration(of: simulator, settledWithin: budget)
        guard isSettled(configuration) else {
            logger.info().log("Display configuration still changing after \(budget) s")
            throw DisplaysStillChangingError(simulatorUDID: simulator.udid, budget: budget)
        }
        return configuration
    }

    /// IDB's configuration, settled or not, with AXe's error text.
    static func configuration(
        of simulator: Simulator,
        settledWithin budget: TimeInterval
    ) async throws -> FBSimulatorControl.SimulatorDisplayConfiguration {
        do {
            return try await simulator.displays.configuration(settledWithin: .seconds(max(budget, 0)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw displayReadError(simulatorUDID: simulator.udid, detail: error.localizedDescription)
        }
    }

    nonisolated static func isSettled(_ configuration: FBSimulatorControl.SimulatorDisplayConfiguration) -> Bool {
        if case .settled = configuration.phase {
            return true
        }
        return false
    }

    /// Fills `DisplayIDCache` once, before a hinge or rotation polls the displays, so the polling
    /// loops never run devicectl. Failures only leave the IDs unknown.
    static func prefetchDisplayIDs(of simulator: Simulator, logger: AxeLogger) async {
        do {
            _ = try await readConfiguration(of: simulator, logger: logger)
        } catch {
            logger.info().log("Display ID prefetch skipped: \(error.localizedDescription)")
        }
    }

    typealias DisplayIDLookup = @MainActor (_ simulatorUDID: String, _ logger: AxeLogger) async throws -> SimulatorDisplayState

    /// devicectl display IDs by unique ID for the `needed` displays: from the cache when it knows
    /// every one of them (or nothing is needed), otherwise from one devicectl read, which refreshes
    /// the cache. A failed or incomplete read is remembered for the rest of the process, so
    /// devicectl runs at most once per simulator per process when it fails. Displays without an
    /// ID then carry `SimulatorDisplay.unknownDisplayID`.
    static func displayIDs(
        needed: Set<String>,
        simulatorUDID: String,
        logger: AxeLogger,
        lookup: DisplayIDLookup = { udid, logger in try await readWithDevicectl(simulatorUDID: udid, logger: logger) }
    ) async -> [String: Int] {
        let cached = DisplayIDCache.ids(forSimulatorUDID: simulatorUDID)
        if needed.isEmpty {
            return cached ?? [:]
        }
        if let cached, needed.isSubset(of: Set(cached.keys)) {
            return cached
        }
        guard !DisplayIDCache.isLookupUnavailable(forSimulatorUDID: simulatorUDID) else {
            return cached ?? [:]
        }
        do {
            let ids = DisplayIDCache.store(try await lookup(simulatorUDID, logger), forSimulatorUDID: simulatorUDID)
            if !needed.isSubset(of: Set(ids.keys)) {
                logger.info().log("devicectl did not report every display; not asking it again in this process")
                DisplayIDCache.markLookupUnavailable(forSimulatorUDID: simulatorUDID)
            }
            return ids
        } catch {
            logger.info().log("Display IDs unavailable; not asking devicectl again in this process: \(error.localizedDescription)")
            DisplayIDCache.markLookupUnavailable(forSimulatorUDID: simulatorUDID)
            return cached ?? [:]
        }
    }

    /// Runs `xcrun devicectl device info displays`, decodes the result and refreshes the display ID cache.
    static func readWithDevicectl(simulatorUDID: String, logger: AxeLogger) async throws -> SimulatorDisplayState {
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
            logger.info().log("Display state (devicectl): \(summary(of: state))")
            DisplayIDCache.store(state, forSimulatorUDID: simulatorUDID)
            return state
        } catch {
            throw devicectlError(simulatorUDID: simulatorUDID, detail: error.localizedDescription)
        }
    }

    private static func summary(of state: SimulatorDisplayState) -> String {
        state.displays
            .map { "\($0.displayId)/\($0.name) active=\($0.active.map(String.init) ?? "nil") primary=\($0.primary) \($0.currentOrientation ?? "?")" }
            .joined(separator: ", ")
    }

    private static func devicectlError(simulatorUDID: String, detail: String) -> DevicectlDisplayReadError {
        DevicectlDisplayReadError(simulatorUDID: simulatorUDID, detail: detail)
    }

    private static func displayReadError(simulatorUDID: String, detail: String) -> CLIError {
        let suffix = detail.isEmpty ? "" : " (\(detail))"
        return CLIError(
            errorDescription: "AXe could not read the displays of simulator \(simulatorUDID)\(suffix). Foldable simulators require Xcode 27.1 or later. Set AXE_DISPLAY_PROBE=never to skip display detection."
        )
    }

    /// Resolves the display to capture for a screenshot or a recording.
    ///
    /// Returns `nil` when IDB's capture of the active display applies: a single display with
    /// `auto`, and with `idbCapturesActiveDisplay` also `auto` on a foldable. Returns the simctl
    /// `--display` argument otherwise: the display's unique ID, which simctl accepts like its
    /// numeric ID.
    ///
    /// The display state is read once any fold has settled, so `auto` names the lit display.
    static func captureDisplayArgument(
        selection: DisplaySelection,
        simulator: Simulator,
        idbCapturesActiveDisplay: Bool = false,
        logger: AxeLogger
    ) async throws -> String? {
        if idbCapturesActiveDisplay, selection == .auto {
            return nil
        }
        let state = try await state(for: simulator, logger: logger)
        let capture = try DisplayCapture.resolve(
            selection: selection,
            state: state,
            isFoldableWithProbeDisabled: state == nil && policy == .never && isFoldable(simulator)
        )
        switch capture {
        case .framebuffer:
            return nil
        case .unvalidatedDisplay(let argument):
            return argument
        case .display(let display):
            if let warning = DisplayCapture.inactiveDisplayWarning(for: display, selection: selection) {
                print(warning, to: &standardError)
            }
            logger.info().log("Capturing display \(display.label)")
            return display.uniqueId.isEmpty ? String(display.displayId) : display.uniqueId
        }
    }

    /// Throws unless `stream-video` can stream the selected display (see `StreamCapture`).
    static func validateStreamDisplay(
        selection: DisplaySelection,
        simulator: Simulator,
        logger: AxeLogger
    ) async throws {
        let state = try await state(for: simulator, logger: logger)
        try StreamCapture.validate(
            selection: selection,
            state: state,
            isFoldableWithProbeDisabled: state == nil && policy == .never && isFoldable(simulator)
        )
    }

    /// Captures one display with `xcrun simctl io <udid> screenshot --display=<display>`.
    static func captureScreenshot(
        simulatorUDID: String,
        display: String,
        to outputURL: URL,
        timeout: TimeInterval = screenshotTimeout
    ) async throws {
        let result: ProcessResult
        do {
            result = try await XcrunProcess.run(
                ["simctl", "io", simulatorUDID, "screenshot", "--type=png", "--display=\(display)", outputURL.path],
                timeout: timeout
            )
        } catch {
            // simctl writes the file before it exits; a slow exit must not discard a good capture.
            guard Self.isPNGFile(at: outputURL) else { throw error }
            FileHandle.standardError.write(Data("Warning: simctl did not exit cleanly after writing \(outputURL.path); keeping the capture.\n".utf8))
            return
        }
        guard result.status == 0 else {
            let detail = result.failureDetail
            throw CLIError(
                errorDescription: "AXe could not capture display \(display) of simulator \(simulatorUDID)" + (detail.isEmpty ? "." : ": \(detail)")
            )
        }
    }

    /// True when the file exists and starts with the PNG signature.
    nonisolated static func isPNGFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard let header = try? handle.read(upToCount: signature.count) else { return false }
        return Array(header) == signature
    }
}

/// `xcrun devicectl device info displays` failed or returned something AXe could not use.
struct DevicectlDisplayReadError: Error, LocalizedError {
    let simulatorUDID: String
    let detail: String

    var errorDescription: String? {
        let suffix = detail.isEmpty ? "" : " (\(detail))"
        return "AXe could not read the displays of simulator \(simulatorUDID) with `xcrun devicectl device info displays`\(suffix). Foldable simulators require Xcode 27.1 or later. Set AXE_DISPLAY_PROBE=never to skip display detection."
    }
}

/// IDB still reported a display transition (a fold, unfold or rotation in progress) when the
/// settle budget ran out. AXe never uses or caches such a configuration: its displays are the
/// outgoing ones.
struct DisplaysStillChangingError: Error, LocalizedError {
    let simulatorUDID: String
    let budget: TimeInterval

    var errorDescription: String? {
        "The displays of simulator \(simulatorUDID) were still changing after \(Int(budget.rounded())) s (a fold, unfold or rotation had not settled). Wait a moment and try again; run `axe posture` to check the active display."
    }
}

// MARK: - Display ID Cache

/// devicectl's numeric display IDs by display unique ID, per simulator.
///
/// IDB reports displays by unique ID only. AXe keeps the numeric IDs for `--display <id>`, the
/// `axe posture` output and its messages, so it reads them with devicectl once and keeps them in
/// `~/Library/Caches/AXe/display-ids/<UDID>.json`. A display whose unique ID is not in the file
/// (a new device, or IDs that changed) triggers one more devicectl read. A failed read is
/// remembered in memory only, for the rest of the process.
@MainActor
enum DisplayIDCache {
    private static var memory: [String: [String: Int]] = [:]
    private static var lookupUnavailable: Set<String> = []

    /// True once a devicectl ID lookup for this simulator failed in this process.
    static func isLookupUnavailable(forSimulatorUDID simulatorUDID: String) -> Bool {
        lookupUnavailable.contains(simulatorUDID)
    }

    static func markLookupUnavailable(forSimulatorUDID simulatorUDID: String) {
        lookupUnavailable.insert(simulatorUDID)
    }

    /// Directory of the cache files; tests point it elsewhere.
    static var directory: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("AXe/display-ids", isDirectory: true)

    static func ids(forSimulatorUDID simulatorUDID: String) -> [String: Int]? {
        if let cached = memory[simulatorUDID] {
            return cached
        }
        guard let url = fileURL(forSimulatorUDID: simulatorUDID),
              let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return nil
        }
        memory[simulatorUDID] = ids
        return ids
    }

    /// Records the IDs of `state` and returns them. Write failures only lose the cache.
    @discardableResult
    static func store(_ state: SimulatorDisplayState, forSimulatorUDID simulatorUDID: String) -> [String: Int] {
        let ids = Dictionary(
            state.displays.filter { !$0.uniqueId.isEmpty && $0.hasKnownDisplayID }.map { ($0.uniqueId, $0.displayId) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !ids.isEmpty, ids != memory[simulatorUDID] else { return ids }
        memory[simulatorUDID] = ids
        if let url = fileURL(forSimulatorUDID: simulatorUDID),
           let data = try? JSONEncoder().encode(ids) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return ids
    }

    static func clearMemory() {
        memory.removeAll()
        lookupUnavailable.removeAll()
    }

    private static func fileURL(forSimulatorUDID simulatorUDID: String) -> URL? {
        let name = simulatorUDID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !name.isEmpty else { return nil }
        return directory?.appendingPathComponent("\(name).json")
    }
}
