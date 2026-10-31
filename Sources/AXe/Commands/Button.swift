import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

enum ButtonType: String, CaseIterable, ExpressibleByArgument, Sendable {
    case applePay = "apple-pay"
    case home = "home"
    case lock = "lock"
    case sideButton = "side-button"
    case siri = "siri"
    case playPause = "play-pause"
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"

    /// Gap between the two side-button presses that make up an Apple Pay press over DTUHID.
    static let applePayPressGap: TimeInterval = 0.15

    var hidButton: SimulatorHIDButton {
        switch self {
        case .applePay:
            return .applePay
        case .home:
            return .homeButton
        case .lock:
            return .lock
        case .sideButton:
            return .sideButton
        case .siri:
            return .siri
        case .playPause:
            return .playPause
        case .volumeUp:
            return .volumeUp
        case .volumeDown:
            return .volumeDown
        }
    }

    var description: String {
        switch self {
        case .applePay:
            return "Apple Pay button"
        case .home:
            return "Home button"
        case .lock:
            return "Lock/Power button"
        case .sideButton:
            return "Side button"
        case .siri:
            return "Siri button"
        case .playPause:
            return "Play/Pause button"
        case .volumeUp:
            return "Volume Up button"
        case .volumeDown:
            return "Volume Down button"
        }
    }

    /// The buttons a platform's simulator accepts, in help order. watchOS `home` is the Digital
    /// Crown press. tvOS takes the Siri Remote's consumer buttons; its d-pad, select and menu are
    /// `axe remote`. visionOS takes none (see `PlatformSupport.visionOSInputUnsupportedMessage`).
    static func supported(on platform: SimulatorPlatform) -> [ButtonType] {
        switch platform {
        case .iOS, .unknown:
            return [.applePay, .home, .lock, .sideButton, .siri]
        case .watchOS:
            return [.home, .sideButton, .lock, .siri]
        case .tvOS:
            return [.playPause, .volumeUp, .volumeDown]
        case .visionOS:
            return []
        }
    }

    /// Throws a validation error naming the platform and its buttons when `platform` has no such
    /// button, and the visionOS input error on visionOS.
    func validate(for platform: SimulatorPlatform) throws {
        try PlatformSupport.check(.button, on: platform)
        let supported = Self.supported(on: platform)
        guard supported.contains(self) else {
            let names = supported.map(\.rawValue).joined(separator: ", ")
            var message = platform == .unknown
                ? "Button '\(rawValue)' is not available on this simulator, which runs an unrecognised platform (treated as iOS). Valid buttons: \(names)."
                : "Button '\(rawValue)' is not available on \(platform.displayName) simulators. Valid buttons on \(platform.displayName): \(names)."
            if platform == .tvOS {
                message += " Use `axe remote up|down|left|right|select|menu` for the Siri Remote d-pad, select and menu."
            }
            // A CLIError, not a ValidationError: thrown from run(), ArgumentParser would follow a
            // ValidationError with the root command's usage line, which says nothing about buttons.
            throw CLIError(errorDescription: message)
        }
    }

    /// Validates against the platform of the simulator with `simulatorUDID`, as `lookup` reports
    /// it (`nil` = no such simulator). A missing simulator throws `CLIError.simulatorNotFound`
    /// before any platform refusal.
    func validate(simulatorUDID: String, lookup: (String) throws -> SimulatorPlatform?) throws {
        try validate(for: PlatformSupport.resolvePlatform(udid: simulatorUDID, lookup: lookup))
    }

    @MainActor
    func validate(simulatorUDID: String, logger: AxeLogger) throws {
        try validate(for: SimulatorSession.requirePlatform(udid: simulatorUDID, logger: logger))
    }

    /// The HID event for one press, held for `duration` seconds when given.
    ///
    /// DTUHID has no Apple Pay usage: Apple Pay is a double side-button press, and IDB refuses
    /// `.applePay` on that transport. Over DTUHID AXe sends two side-button presses
    /// `applePayPressGap` apart, each held for half of `duration`.
    func pressEvent(duration: Double?, overDTUHID: Bool) -> SimulatorHIDEvent {
        if self == .applePay, overDTUHID {
            let half = duration.map { $0 / 2 }
            return .composite([
                Self.press(.sideButton, duration: half),
                .delay(Self.applePayPressGap),
                Self.press(.sideButton, duration: half),
            ])
        }
        return Self.press(hidButton, duration: duration)
    }

    private static func press(_ button: SimulatorHIDButton, duration: Double?) -> SimulatorHIDEvent {
        guard let duration else {
            return .shortButtonPress(button)
        }
        return .composite([
            .button(direction: .down, button: button),
            .delay(duration),
            .button(direction: .up, button: button),
        ])
    }

    /// Presses the button in `session`.
    ///
    /// The transport is predicted from the CoreSimulator version, as IDB chooses it. Should IDB
    /// still refuse `.applePay` because it negotiated DTUHID, nothing was sent (the refusal comes
    /// on the first button-down), so the press is resent as two side-button presses.
    @MainActor
    func perform(duration: Double?, in session: HIDInteractor.Session, logger: AxeLogger) async throws {
        let overDTUHID = self == .applePay && HIDBroker.usesDTUHID()
        do {
            try await HIDInteractor.performHIDEvent(pressEvent(duration: duration, overDTUHID: overDTUHID), in: session, logger: logger)
        } catch SimulatorHIDError.notImplementedOnDTUHIDTransport where self == .applePay && !overDTUHID {
            logger.info().log("IDB refused the Apple Pay usage on DTUHID; sending two side-button presses instead")
            try await HIDInteractor.performHIDEvent(pressEvent(duration: duration, overDTUHID: true), in: session, logger: logger)
        } catch SimulatorHIDError.notImplementedOnDTUHIDTransport {
            throw CLIError(
                errorDescription: "The simulator's input transport (DTUHID) cannot press \(description). No button was pressed."
            )
        }
    }
}

struct Button: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a hardware button on the simulator.",
        discussion: """
        Available buttons by platform (`axe list-simulators` shows each simulator's platform):
          iOS/iPadOS: apple-pay, home, lock, side-button, siri
          watchOS:    home (Digital Crown press), side-button, lock, siri
          tvOS:       play-pause, volume-up, volume-down
                      (Siri Remote d-pad, select and menu: `axe remote`)
          visionOS:   not supported
        A button the simulator's platform does not have is refused before anything is sent.

        Examples:
          axe button home --udid SIMULATOR_UDID
          axe button lock --duration 2.0 --udid SIMULATOR_UDID
          axe button siri --udid SIMULATOR_UDID
          axe button play-pause --udid SIMULATOR_UDID
        """
    )

    @Argument(help: "The button to press.")
    var buttonType: ButtonType

    @Option(name: .customLong("duration"), help: "Duration to hold the button in seconds (optional).")
    var duration: Double?

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    func validate() throws {
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            guard duration <= 10.0 else {
                throw ValidationError("Duration must not exceed 10 seconds.")
            }
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)

        try await performGlobalSetup(logger: logger)

        try await buttonType.validate(simulatorUDID: simulatorUDID, logger: logger)

        logger.info().log("Pressing \(buttonType.description)")
        if let duration = duration {
            logger.info().log("Duration: \(duration) seconds")
        }

        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        try await buttonType.perform(duration: duration, in: session, logger: logger)

        logger.info().log("\(buttonType.description) press completed successfully")
    }
}
