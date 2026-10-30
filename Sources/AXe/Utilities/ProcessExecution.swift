import Darwin
import Foundation

// MARK: - Process Execution

struct ProcessResult {
    let status: Int32
    let standardOutput: Data
    let standardError: Data

    /// The most useful one-line explanation of a failed xcrun tool, for error messages.
    var failureDetail: String {
        XcrunFailureDetail.summary(standardOutput: standardOutput, standardError: standardError)
    }

    var standardOutputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }
}

enum XcrunFailureDetail {
    /// Extracts the failure reason from devicectl or simctl output.
    ///
    /// Order: `error.userInfo.NSLocalizedDescription` from a devicectl JSON envelope (stdout or
    /// stderr); the first stderr line starting with `ERROR:` or `Error:`, without the prefix; the
    /// first non-empty stderr line. simctl prints progress such as "Detected file type" first and
    /// a bare "Invalid argument" last, so neither end of stderr is reliable on its own.
    static func summary(standardOutput: Data, standardError: Data) -> String {
        if let message = jsonErrorDescription(in: standardOutput) ?? jsonErrorDescription(in: standardError) {
            return message
        }
        let lines = String(decoding: standardError, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for prefix in ["ERROR:", "Error:"] {
            if let line = lines.first(where: { $0.hasPrefix(prefix) }) {
                return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return lines.first ?? ""
    }

    private struct ErrorEnvelope: Decodable {
        let error: DeviceCtlErrorPayload?
    }

    private static func jsonErrorDescription(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        let json = Data(text[start...end].utf8)
        guard let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: json))?.error?.localizedDescription,
              !message.isEmpty else {
            return nil
        }
        return message
    }
}

/// Runs a host tool with a timeout and captures stdout and stderr.
enum ProcessRunner {
    /// Maximum time to wait for pipe EOF after the child exits. A descendant that inherited the
    /// pipe write ends must not turn the bounded timeout into an unbounded wait.
    static let pipeDrainTimeout: TimeInterval = 1

    /// - Parameter displayName: name used in the timeout error, for example `xcrun devicectl`.
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        displayName: String
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain both pipes as data arrives so a large payload cannot block the child.
        let output = PipeCollector(outputPipe.fileHandleForReading)
        let errors = PipeCollector(errorPipe.fileHandleForReading)
        defer {
            output.stop()
            errors.stop()
        }

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                // Cancelled: a cancelled sleep returns at once, so polling on would spin.
                stop(process)
                throw CancellationError()
            }
        }
        if process.isRunning {
            stop(process)
            throw CLIError(errorDescription: "\(displayName) timed out after \(Int(timeout.rounded(.up))) seconds.")
        }
        // `isRunning` is already false here, so `terminationStatus` is valid. `waitUntilExit()` is not
        // called: on the main thread it can block forever in its run loop when the termination was
        // already observed, which happened after several back-to-back devicectl calls.

        let drainDeadline = Date().addingTimeInterval(pipeDrainTimeout)
        while !(output.isFinished && errors.isFinished), Date() < drainDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: output.data,
            standardError: errors.data
        )
    }

    /// Sends SIGTERM, then SIGKILL after 0.5 s, and waits up to 1 s more for the exit. Uses a
    /// blocking sleep so it also works in a cancelled task; the wait is bounded at 1.5 s.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < terminateDeadline {
            usleep(10_000)
        }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < killDeadline {
            usleep(10_000)
        }
    }
}

enum XcrunProcess {
    static func run(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments,
            timeout: timeout,
            displayName: "xcrun \(arguments.first ?? "")"
        )
    }
}

/// Collects a pipe's output through `readabilityHandler`, without blocking a thread on the read.
final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readable in
            let chunk = readable.availableData
            if chunk.isEmpty {
                readable.readabilityHandler = nil
            }
            self?.append(chunk)
        }
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Detaches the handler and closes the read end. Safe to call more than once.
    func stop() {
        handle.readabilityHandler = nil
        try? handle.close()
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if chunk.isEmpty {
            finished = true
        } else {
            buffer.append(chunk)
        }
    }
}
