import ArgumentParser
import Foundation

struct Focus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move tvOS focus to an element by accessibility label or identifier.",
        discussion: """
        Reads the accessibility tree, finds the target and the focused element, presses the Siri Remote d-pad toward the target (up or down first, then left or right, from the centres of their frames), reads the tree again, and repeats until the target has focus. With --select, presses select once it has. Elements a remote can focus (buttons, cells) are preferred over text with the same label, and focus on an element that contains the target's centre (a cell around its title) counts as reached.

        After a screen change, --wait-timeout polls the tree until the target and a focused element appear before the first press.

        Fails, after the presses already sent, when the target is not in the tree or is ambiguous, when no element has focus, when focus stops moving (every direction toward the target was pressed from the focused element without effect), or when --max-steps presses did not reach it. The target must be in the accessibility tree: an item of a lazy list that is not loaded yet cannot be found.

        tvOS simulators only; other platforms are refused before anything is sent.

        Examples:
          axe focus --label "General" --udid SIMULATOR_UDID
          axe focus --label "Developer" --select --udid SIMULATOR_UDID
          axe focus --id AppCell --max-steps 20 --udid SIMULATOR_UDID
        """
    )

    @Option(name: .customLong("label"), help: "The accessibility label of the element to focus.")
    var elementLabel: String?

    @Option(name: .customLong("id"), help: "The accessibility identifier (AXUniqueId) of the element to focus.")
    var elementID: String?

    @Option(name: .customLong("max-steps"), help: "Maximum d-pad presses, 1 to 500 (default: 50).")
    var maxSteps: Int = FocusRequest.defaultMaxSteps

    @Flag(name: .customLong("select"), help: "Press select once the target has focus.")
    var select = false

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the target and a focused element before the first press, for a screen still in transition (0 = no waiting, default).")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25).")
    var pollInterval: Double = 0.25

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    var query: FocusQuery {
        if let elementID {
            return .id(elementID)
        }
        return .label(elementLabel ?? "")
    }

    var request: FocusRequest {
        FocusRequest(query: query, maxSteps: maxSteps, select: select)
            .waiting(seconds: waitTimeout, pollSeconds: pollInterval)
    }

    func validate() throws {
        switch (elementLabel, elementID) {
        case (nil, nil):
            throw ValidationError("Specify the element to focus with --label or --id.")
        case (.some, .some):
            throw ValidationError("Specify only one of --label or --id.")
        default:
            break
        }
        let value = (elementLabel ?? elementID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ValidationError("--label and --id must not be empty.")
        }
        guard (1...FocusRequest.maximumMaxSteps).contains(maxSteps) else {
            throw ValidationError("--max-steps must be between 1 and \(FocusRequest.maximumMaxSteps).")
        }
        guard waitTimeout.isFinite, waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }
        if waitTimeout > 0 {
            guard pollInterval.isFinite, pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        try await PlatformSupport.check(.focus, simulatorUDID: simulatorUDID, logger: logger)

        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        let result = try await FocusNavigator.navigate(request, simulatorUDID: simulatorUDID, logger: logger) { action in
            try await HIDInteractor.performHIDEvent(action.pressEvent, in: session, logger: logger)
        }
        print("✓ \(result.summary)")
    }
}
