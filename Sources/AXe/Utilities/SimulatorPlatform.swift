import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Simulator Platform

/// The operating system family a simulator runs, as far as AXe's input and coordinate handling
/// cares. iPadOS reports as `iOS`: AXe drives iPhone and iPad simulators the same way.
enum SimulatorPlatform: String, CaseIterable, Sendable {
    case iOS
    case watchOS
    case tvOS
    case visionOS
    case unknown

    /// The name printed by `list-simulators` and used in error messages.
    var displayName: String {
        rawValue
    }

    /// The platform as it reads after "runs" or "on" in a message: the name, or "an unrecognised
    /// platform" for a simulator whose family and runtime AXe does not recognise.
    var phrase: String {
        self == .unknown ? "an unrecognised platform" : displayName
    }

    /// Derives the platform from IDB's simulator configuration.
    ///
    /// IDB maps CoreSimulator's product family IDs 1-4 (iPhone, iPad, Apple TV, Apple Watch) and
    /// reports Apple Vision Pro (product family 7) as `.unknown`, so the runtime identifier
    /// (`com.apple.CoreSimulator.SimRuntime.xrOS-<version>`) and then the runtime name decide the
    /// remaining cases.
    static func derive(family: ProductFamily, runtimeIdentifier: String?, runtimeName: String?) -> SimulatorPlatform {
        switch family {
        case .iPhone, .iPad:
            return .iOS
        case .appleTV:
            return .tvOS
        case .appleWatch:
            return .watchOS
        default:
            break
        }
        if let runtimeIdentifier, let platform = fromRuntimeIdentifier(runtimeIdentifier) {
            return platform
        }
        if let runtimeName, let platform = fromRuntimeName(runtimeName) {
            return platform
        }
        return .unknown
    }

    init(configuration: SimulatorConfiguration) {
        self = Self.derive(
            family: configuration.device.family,
            runtimeIdentifier: configuration.runtimeIdentifier,
            runtimeName: configuration.os.name.rawValue
        )
    }

    /// `com.apple.CoreSimulator.SimRuntime.<platform>-<version>`; visionOS runtimes are named `xrOS`.
    private static func fromRuntimeIdentifier(_ identifier: String) -> SimulatorPlatform? {
        guard let last = identifier.split(separator: ".").last else { return nil }
        let platform = last.split(separator: "-").first.map(String.init)?.lowercased()
        switch platform {
        case "ios":
            return .iOS
        case "watchos":
            return .watchOS
        case "tvos":
            return .tvOS
        case "xros", "visionos":
            return .visionOS
        default:
            return nil
        }
    }

    /// A runtime name such as `visionOS 27.2`.
    private static func fromRuntimeName(_ name: String) -> SimulatorPlatform? {
        let first = name.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased()
        switch first {
        case "ios", "ipados":
            return .iOS
        case "watchos":
            return .watchOS
        case "tvos":
            return .tvOS
        case "visionos", "xros":
            return .visionOS
        default:
            return nil
        }
    }

    /// True where AXe's portrait-phone coordinate model (rotation inference from the accessibility
    /// frame, landscape-only letterboxing) applies. An unknown platform keeps the iOS behaviour.
    var usesPhoneCoordinateModel: Bool {
        switch self {
        case .iOS, .unknown:
            return true
        case .watchOS, .tvOS, .visionOS:
            return false
        }
    }
}

extension Simulator {
    /// The simulator's platform, derived from its configuration (no simulator round-trip).
    var platform: SimulatorPlatform {
        SimulatorPlatform(configuration: configuration)
    }
}

// MARK: - Platform Support

/// Which kinds of input and device commands each platform accepts, and the errors AXe reports
/// before it connects to the simulator's HID service or Device Hub.
enum PlatformSupport {
    enum Input: Sendable {
        /// Touch-screen input: tap, swipe, drag, gesture, touch, slider, selector taps.
        case touch
        /// Hardware buttons (`axe button`).
        case button
        /// Keyboard input: type, key, key-sequence, key-combo.
        case keyboard
        /// Siri Remote focus input (`axe remote`).
        case remote
        /// Digital Crown rotation (`axe crown`).
        case crown
    }

    static let visionOSInputUnsupportedMessage = "Input is not supported on visionOS simulators: the bundled IDB drives only the touch digitizer service, which visionOS does not provide"

    static let tvOSTouchUnsupportedMessage = "Touch input is not available on tvOS simulators; use `axe remote`"

    static func iOSOnlyMessage(command: String, platform: SimulatorPlatform) -> String {
        "\(command.prefix(1).uppercased())\(command.dropFirst()) is only available on iOS simulators (this simulator runs \(platform.phrase))"
    }

    static func remoteOnlyMessage(platform: SimulatorPlatform) -> String {
        "Remote is only available on tvOS simulators (this simulator runs \(platform.phrase)); use `axe tap`, `axe swipe` or `axe button` instead"
    }

    static func crownOnlyMessage(platform: SimulatorPlatform) -> String {
        "Crown is only available on watchOS simulators (this simulator runs \(platform.phrase))"
    }

    /// Throws when `platform` cannot take `input`.
    static func check(_ input: Input, on platform: SimulatorPlatform) throws {
        if input == .remote {
            guard platform == .tvOS else {
                throw CLIError(errorDescription: remoteOnlyMessage(platform: platform))
            }
            return
        }
        if input == .crown {
            guard platform == .watchOS else {
                throw CLIError(errorDescription: crownOnlyMessage(platform: platform))
            }
            return
        }
        if platform == .visionOS {
            throw CLIError(errorDescription: visionOSInputUnsupportedMessage)
        }
        if input == .touch, platform == .tvOS {
            throw CLIError(errorDescription: tvOSTouchUnsupportedMessage)
        }
    }

    /// Throws unless `platform` is iOS (or unknown, which keeps the iOS behaviour).
    static func requireIOS(command: String, on platform: SimulatorPlatform) throws {
        guard platform.usesPhoneCoordinateModel else {
            throw CLIError(errorDescription: iOSOnlyMessage(command: command, platform: platform))
        }
    }

    /// The platform `lookup` reports for `udid`; throws `CLIError.simulatorNotFound` when `lookup`
    /// finds no simulator, so a mistyped UDID is never reported as a platform refusal.
    static func resolvePlatform(
        udid: String,
        lookup: (String) throws -> SimulatorPlatform?
    ) throws -> SimulatorPlatform {
        guard let platform = try lookup(udid) else {
            throw CLIError.simulatorNotFound(udid: udid)
        }
        return platform
    }

    /// Checks `input` against the platform of the simulator with `simulatorUDID`. Throws
    /// `CLIError.simulatorNotFound` first when there is no such simulator.
    @MainActor
    @discardableResult
    static func check(_ input: Input, simulatorUDID: String, logger: AxeLogger) throws -> SimulatorPlatform {
        try check(input, simulatorUDID: simulatorUDID) {
            try SimulatorSession.simulator(udid: $0, logger: logger)?.platform
        }
    }

    /// `check(_:simulatorUDID:logger:)` with an injectable lookup (`nil` = no such simulator).
    @discardableResult
    static func check(
        _ input: Input,
        simulatorUDID: String,
        lookup: (String) throws -> SimulatorPlatform?
    ) throws -> SimulatorPlatform {
        let platform = try resolvePlatform(udid: simulatorUDID, lookup: lookup)
        try check(input, on: platform)
        return platform
    }

    @MainActor
    static func requireIOS(command: String, simulatorUDID: String, logger: AxeLogger) throws {
        try requireIOS(command: command, on: SimulatorSession.requirePlatform(udid: simulatorUDID, logger: logger))
    }
}
