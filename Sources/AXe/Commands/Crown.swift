import ArgumentParser
import FBControlCore
import FBSimulatorControl
import Foundation

/// One Digital Crown rotation: `delta` split into `steps` equal reports `intervalMilliseconds` apart,
/// as IDB's `SimulatorHIDCommands.rotateDigitalCrown(by:steps:interval:)` sends it.
struct CrownRotation: Equatable, Sendable {
    /// IDB's defaults for `rotateDigitalCrown`.
    static let defaultSteps = 10
    static let defaultIntervalMilliseconds = 16

    static let maximumSteps = 1_000
    static let maximumIntervalMilliseconds = 1_000
    static let maximumMagnitude = 10_000.0

    let delta: Double
    let steps: Int
    let intervalMilliseconds: Int

    /// The crown delta each report carries.
    var deltaPerStep: Double {
        delta / Double(steps)
    }

    var interval: Duration {
        .milliseconds(intervalMilliseconds)
    }

    /// Throws a validation error for a rotation IDB cannot send or the watch would not notice.
    func validate() throws {
        guard delta.isFinite, delta != 0, abs(delta) <= Self.maximumMagnitude else {
            throw ValidationError("--delta must be a non-zero number between -\(Int(Self.maximumMagnitude)) and \(Int(Self.maximumMagnitude)).")
        }
        guard (1...Self.maximumSteps).contains(steps) else {
            throw ValidationError("--steps must be between 1 and \(Self.maximumSteps).")
        }
        guard (0...Self.maximumIntervalMilliseconds).contains(intervalMilliseconds) else {
            throw ValidationError("--interval-ms must be between 0 and \(Self.maximumIntervalMilliseconds).")
        }
    }

    /// Turns the crown of `simulator` over dtuhidd's scroll service.
    @MainActor
    func perform(on simulator: Simulator, logger: AxeLogger) async throws {
        logger.info().log("Turning the Digital Crown by \(delta) in \(steps) step(s) \(intervalMilliseconds) ms apart")
        do {
            try await simulator.hid.rotateDigitalCrown(by: delta, steps: steps, interval: interval)
        } catch {
            throw Self.userFacingError(for: error)
        }
    }

    /// Waits until the content the rotation scrolled has stopped moving: reads the accessibility
    /// tree every `policy.interval` until two consecutive reads report the same elements and
    /// frames (`UISettle`). The watch keeps scrolling after the last report while the content
    /// decelerates, so a `describe-ui` or selector tap sent at once can see moving frames.
    ///
    /// Never fails the command: a timeout, or a tree that cannot be read, prints a warning on
    /// stderr and returns. Only cancellation propagates.
    ///
    /// - Returns: the outcome, or `nil` when the tree could not be read.
    @MainActor
    @discardableResult
    static func waitForScrollToSettle(
        simulatorUDID: String,
        policy: UISettlePolicy,
        logger: AxeLogger,
        warn: (String) -> Void = { print($0, to: &standardError) }
    ) async throws -> UISettleOutcome? {
        let start = ContinuousClock.now
        do {
            let outcome = try await UISettle.waitUntilStable(
                policy: policy,
                snapshot: {
                    AccessibilityLayoutSignature(
                        roots: try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
                    )
                },
                elapsed: { ContinuousClock.now - start },
                sleep: { try await Task.sleep(for: $0) }
            )
            logger.info().log("Digital Crown settle: \(outcome)")
            if let warning = settleWarning(for: outcome, policy: policy) {
                warn(warning)
            }
            return outcome
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warn(settleReadFailureWarning(error))
            return nil
        }
    }

    /// ` (settled in 0.6 s)` after the success line when the content settled; empty otherwise.
    static func settleSuffix(for outcome: UISettleOutcome?) -> String {
        guard case .settled(let elapsed, _)? = outcome else { return "" }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return " (settled in \(String(format: "%.1f", seconds)) s)"
    }

    /// The stderr warning for a settle that ran out of time; `nil` when the content settled.
    static func settleWarning(for outcome: UISettleOutcome, policy: UISettlePolicy) -> String? {
        guard case .timedOut = outcome else { return nil }
        return "Warning: the content was still moving \(Crown.format(policy.timeoutSeconds)) s after the Digital Crown rotation (--settle-timeout); the next command may see it move. The rotation was sent."
    }

    static func settleReadFailureWarning(_ error: Error) -> String {
        "Warning: could not read the accessibility tree to wait for the scroll to settle (\(error.localizedDescription)); returning without waiting. The rotation was sent."
    }

    /// Maps IDB's "no DTUHID crown input here" errors to a message naming the Xcode 27 requirement;
    /// returns any other error unchanged.
    static func userFacingError(for error: Error) -> Error {
        switch error as? SimulatorHIDError {
        case .dtuhidServiceNotVended(let name)?:
            return CLIError(
                errorDescription: "The simulator does not provide the Digital Crown input service (\(name)); it needs a watchOS runtime on Xcode 27 or later (DTUHID input). No rotation was sent."
            )
        case .dtuhidXPCSymbolsUnavailable?:
            return CLIError(
                errorDescription: "This Xcode's CoreSimulator does not provide DTUHID input, which the Digital Crown needs; it needs Xcode 27 or later. No rotation was sent."
            )
        default:
            return error
        }
    }
}

struct Crown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn the Digital Crown of a watchOS simulator.",
        discussion: """
        A positive --delta scrolls content toward its end (down a list), a negative one toward its start. Pass a negative value as `--delta=-50` or `--delta -50`. The rotation is split into --steps reports --interval-ms apart (default 10 reports 16 ms apart). The watch accelerates the crown, so the same delta in fewer, larger or faster steps scrolls further; on watchOS 27.2 `--delta 50` scrolls a Settings list by about one and a half rows. Pressing the crown is `axe button home`.

        The scrolled content keeps moving for a moment after the last report. By default AXe then reads the accessibility tree until two consecutive reads match (the content has settled), for at most --settle-timeout seconds (default 3), so a following `describe-ui` or selector tap sees the final frames. A timeout prints a warning and does not fail the command. --no-settle returns as soon as the rotation is sent.

        watchOS simulators only, over the simulator's DTUHID scroll service; other platforms are refused before anything is sent.

        Examples:
          axe crown --delta 50 --udid SIMULATOR_UDID
          axe crown --delta=-50 --udid SIMULATOR_UDID
          axe crown --delta 200 --steps 20 --interval-ms 16 --udid SIMULATOR_UDID
          axe crown --delta 50 --no-settle --udid SIMULATOR_UDID
        """
    )

    @Option(
        name: .customLong("delta"),
        parsing: .unconditional,
        help: ArgumentHelp("Rotation in the crown's own units; positive scrolls down, negative up (about 50 = one and a half list rows).", valueName: "delta")
    )
    var delta: Double

    @Option(name: .customLong("steps"), help: "Number of reports the rotation is split into, 1 to 1000.")
    var steps: Int = CrownRotation.defaultSteps

    @Option(name: .customLong("interval-ms"), help: "Milliseconds between reports, 0 to 1000.")
    var intervalMilliseconds: Int = CrownRotation.defaultIntervalMilliseconds

    @Flag(name: .customLong("no-settle"), help: "Return as soon as the rotation is sent, without waiting for the scrolled content to stop moving.")
    var noSettle = false

    @Option(
        name: .customLong("settle-timeout"),
        help: ArgumentHelp("Maximum seconds to wait for the scrolled content to stop moving, more than 0 and up to 60 (default: 3). A timeout warns on stderr and does not fail.", valueName: "seconds")
    )
    var settleTimeout: Double?

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    var rotation: CrownRotation {
        CrownRotation(delta: delta, steps: steps, intervalMilliseconds: intervalMilliseconds)
    }

    /// How to wait for the scroll to settle after the rotation; `nil` with --no-settle.
    var settlePolicy: UISettlePolicy? {
        noSettle ? nil : UISettlePolicy(timeoutSeconds: settleTimeout ?? UISettlePolicy.defaultTimeoutSeconds)
    }

    func validate() throws {
        try rotation.validate()
        if let settleTimeout {
            guard !noSettle else {
                throw ValidationError("--settle-timeout cannot be combined with --no-settle.")
            }
            try UISettlePolicy.validateTimeout(settleTimeout)
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        try await PlatformSupport.check(.crown, simulatorUDID: simulatorUDID, logger: logger)

        let simulator = try await SimulatorSession.bootedSimulator(udid: simulatorUDID, logger: logger)
        try await rotation.perform(on: simulator, logger: logger)
        var outcome: UISettleOutcome?
        if let settlePolicy {
            outcome = try await CrownRotation.waitForScrollToSettle(simulatorUDID: simulatorUDID, policy: settlePolicy, logger: logger)
        }
        print("✓ Digital Crown turned by \(Self.format(delta))\(CrownRotation.settleSuffix(for: outcome))")
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}
