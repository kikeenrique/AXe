import ArgumentParser
import FBSimulatorControl
import Foundation

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Execute ordered interaction steps using one simulator/HID session.",
        discussion: """
        Batch executes multiple interaction steps in one command to reduce overhead.
        Steps are executed in order.

        Supported step commands:
          tap, swipe, gesture, touch, type, button, key, key-sequence, key-combo

        Batch-only pseudo-step:
          sleep <seconds>

        Examples:
          axe batch --udid SIMULATOR_UDID --step "tap --id BackButton" --step "type 'hello'"
          axe batch --udid SIMULATOR_UDID --file steps.txt
          cat steps.txt | axe batch --udid SIMULATOR_UDID --stdin
        """
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Option(name: .customLong("step"), help: "Step to execute. Repeat for multiple steps.")
    var steps: [String] = []

    @Option(name: .customLong("file"), help: "Read steps from a file (one step per line).")
    var file: String?

    @Flag(name: .customLong("stdin"), help: "Read steps from stdin (one step per line).")
    var useStdin: Bool = false

    @Option(name: .customLong("ax-cache"), help: "Accessibility snapshot cache policy for selector-based taps.")
    var axCachePolicy: AXCachePolicy = .perBatch

    @Option(name: .customLong("type-submission"), help: "Type step submission mode.")
    var typeSubmissionMode: TypeSubmissionMode = .chunked

    @Option(name: .customLong("type-chunk-size"), help: "Maximum HID events per chunk when type-submission is chunked.")
    var typeChunkSize: Int = 200

    @Option(name: .customLong("tap-style"), help: "Default tap event style for tap steps: automatic uses physical touch for switches/toggles and simulator tap for other targets; simulator always uses FBSimulator tapAt; physical uses touch down/up.")
    var tapStyle: TapStyle = .automatic

    @Flag(name: .customLong("continue-on-error"), help: "Continue executing later steps even if one step fails.")
    var continueOnError: Bool = false

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for selector-based elements before failing (0 = no waiting).")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active.")
    var pollInterval: Double = 0.25

    @Flag(name: .customLong("verbose"), help: "Enable verbose logging to stderr.")
    var verbose: Bool = false

    func validate() throws {
        let sourceCount = [!steps.isEmpty, file != nil, useStdin].filter { $0 }.count
        guard sourceCount == 1 else {
            throw ValidationError("Specify exactly one step source: --step, --file, or --stdin.")
        }

        guard typeChunkSize > 0 else {
            throw ValidationError("--type-chunk-size must be greater than 0.")
        }

        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if waitTimeout > 0 {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    func run() async throws {
        let logger = AxeLogger(writeToStdErr: verbose)
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let stepLines = try loadStepLines()
        if stepLines.isEmpty {
            throw ValidationError("No executable steps found.")
        }

        let context = await MainActor.run {
            BatchContext(
                simulatorUDID: simulatorUDID,
                axCachePolicy: axCachePolicy,
                typeSubmissionMode: typeSubmissionMode,
                typeChunkSize: typeChunkSize,
                tapStyle: tapStyle,
                waitTimeout: waitTimeout,
                pollInterval: pollInterval
            )
        }

        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        let runner = BatchPlanRunner(session: session, logger: logger)

        var failures: [String] = []

        for (index, line) in stepLines.enumerated() {
            var stepName = "<unparsed>"
            do {
                let tokens = try ShellTokenizer.tokenize(line)
                stepName = tokens.first ?? "<empty>"
                let primitives = try await BatchStepParser.parseStepTokens(
                    tokens,
                    globalUDID: simulatorUDID,
                    context: context,
                    logger: logger
                )
                try await runner.run(BatchPlan(primitives: primitives))
            } catch {
                let message = Self.stepFailureMessage(for: error)
                if continueOnError {
                    failures.append("Step \(index + 1) failed: [\(stepName)] -> \(message)")
                } else {
                    throw CLIError(errorDescription: "Step \(index + 1) failed: [\(stepName)]\n\(message)")
                }
            }
        }

        if !failures.isEmpty {
            let failureMessage = failures.joined(separator: "\n")
            throw CLIError(errorDescription: "Batch completed with \(failures.count) failure(s):\n\(failureMessage)")
        }

        print("✓ Batch completed successfully (\(stepLines.count) steps)")
    }

    /// The user-facing text of a step failure.
    static func stepFailureMessage(for error: Error) -> String {
        if let error = error as? SimulatorDisplayError {
            switch error {
            case .changed, .transitioning:
                // IDB binds a step's HID events to the display active at its first touch and stops
                // the step when that display rotates before the step ends.
                return "The simulator display changed (for example a rotation) while this step's input was being sent, so IDB stopped the step; its remaining events were not sent. Re-run the batch from this step. (\(error.localizedDescription))"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func loadStepLines() throws -> [String] {
        let rawLines: [String]
        if !steps.isEmpty {
            rawLines = steps
        } else if let file {
            let contents: String
            do {
                contents = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                throw ValidationError("Failed to read step file '\(file)': \(error.localizedDescription)")
            }
            rawLines = contents.components(separatedBy: .newlines)
        } else {
            rawLines = readStdinLines()
        }

        return rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func readStdinLines() -> [String] {
        var lines: [String] = []
        while let line = readLine() {
            lines.append(line)
        }
        return lines
    }
}

