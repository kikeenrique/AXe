import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

enum ButtonType: String, CaseIterable, ExpressibleByArgument {
    case applePay = "apple-pay"
    case home = "home"
    case lock = "lock"
    case sideButton = "side-button"
    case siri = "siri"

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
        }
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
        Available buttons: apple-pay, home, lock, side-button, siri

        Examples:
          axe button home --udid SIMULATOR_UDID
          axe button lock --duration 2.0 --udid SIMULATOR_UDID
          axe button siri --udid SIMULATOR_UDID
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

        logger.info().log("Pressing \(buttonType.description)")
        if let duration = duration {
            logger.info().log("Duration: \(duration) seconds")
        }

        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        try await buttonType.perform(duration: duration, in: session, logger: logger)

        logger.info().log("\(buttonType.description) press completed successfully")
    }
}
