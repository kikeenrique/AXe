import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

/// A Siri Remote action on a tvOS simulator.
enum RemoteAction: String, CaseIterable, ExpressibleByArgument, Sendable {
    case up
    case down
    case left
    case right
    case select
    case menu
    case playPause = "play-pause"

    /// One press. The d-pad, select and menu are IDB's remote focus actions (keyboard usages the
    /// tvOS focus engine consumes); play-pause is the consumer Play/Pause button.
    var pressEvent: SimulatorHIDEvent {
        switch self {
        case .up:
            return .remoteButton(.up)
        case .down:
            return .remoteButton(.down)
        case .left:
            return .remoteButton(.left)
        case .right:
            return .remoteButton(.right)
        case .select:
            return .remoteButton(.select)
        case .menu:
            return .remoteButton(.menu)
        case .playPause:
            return .shortButtonPress(.playPause)
        }
    }

    /// `count` presses, `delayMilliseconds` apart.
    func events(count: Int, delayMilliseconds: Double) -> SimulatorHIDEvent {
        guard count > 1 else { return pressEvent }
        var events: [SimulatorHIDEvent] = []
        for index in 0..<count {
            if index > 0, delayMilliseconds > 0 {
                events.append(.delay(delayMilliseconds / 1000))
            }
            events.append(pressEvent)
        }
        return .composite(events)
    }
}

struct Remote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a Siri Remote button on a tvOS simulator.",
        discussion: """
        Moves focus with the d-pad (up, down, left, right), activates the focused item (select), goes back (menu), or toggles playback (play-pause). tvOS simulators only; other platforms are refused before anything is sent. Volume: `axe button volume-up|volume-down`.

        Examples:
          axe remote down --udid SIMULATOR_UDID
          axe remote right --count 3 --delay 200 --udid SIMULATOR_UDID
          axe remote select --udid SIMULATOR_UDID
          axe remote menu --udid SIMULATOR_UDID
        """
    )

    static let maximumCount = 100
    static let maximumDelayMilliseconds = 10_000.0
    static let defaultDelayMilliseconds = 150.0

    @Argument(help: "The remote button: up, down, left, right, select, menu, or play-pause.")
    var action: RemoteAction

    @Option(name: .customLong("count"), help: "Number of presses, 1 to 100 (default: 1).")
    var count: Int = 1

    @Option(name: .customLong("delay"), help: "Milliseconds between presses when --count is above 1 (default: 150).")
    var delay: Double = Self.defaultDelayMilliseconds

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    func validate() throws {
        guard (1...Self.maximumCount).contains(count) else {
            throw ValidationError("--count must be between 1 and \(Self.maximumCount).")
        }
        guard delay.isFinite, delay >= 0, delay <= Self.maximumDelayMilliseconds else {
            throw ValidationError("--delay must be between 0 and \(Int(Self.maximumDelayMilliseconds)) milliseconds.")
        }
    }

    /// The HID event for the whole command.
    var event: SimulatorHIDEvent {
        action.events(count: count, delayMilliseconds: delay)
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        try await PlatformSupport.check(.remote, simulatorUDID: simulatorUDID, logger: logger)

        logger.info().log("Pressing remote \(action.rawValue) \(count) time(s)")
        try await HIDInteractor.performHIDEvent(event, for: simulatorUDID, logger: logger)
        logger.info().log("Remote \(action.rawValue) completed successfully")
    }
}
