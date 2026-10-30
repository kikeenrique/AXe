import AVFoundation
import Darwin
import Foundation

/// Records one simulator display with `xcrun simctl io <udid> recordVideo --display=<id>`.
///
/// The idb framebuffer that `record-video` samples by default always shows the inner display of a
/// foldable, so a specific display is recorded through simctl. simctl records H.264 at the
/// display's native size, frame by frame as the display updates, and stops on SIGINT once it has
/// written the file.
enum SimctlVideoRecorder {
    static let codec = "h264"
    static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    /// simctl prints this to stderr once it has processed the first frame. Only a fast path: when it
    /// does not appear within `startTimeout` and simctl is still running, AXe records anyway.
    static let recordingStartedMarker = "Recording started"
    static let startTimeout: TimeInterval = 15
    /// simctl finalises the movie after SIGINT; a long recording on a loaded host can take a while.
    static let finalizeTimeout: TimeInterval = 60
    /// Temporary QuickTime files of runs that died (for example a SIGKILLed AXe) are removed once
    /// they are this old.
    static let staleRecordingAge: TimeInterval = 60 * 60
    static let temporaryRecordingPrefix = ".axe-recording-"

    /// Arguments after `xcrun`.
    static func arguments(simulatorUDID: String, display: String, outputPath: String) -> [String] {
        [
            "simctl", "io", simulatorUDID, "recordVideo",
            "--codec=\(codec)",
            "--display=\(display)",
            "--force",
            outputPath,
        ]
    }

    /// AXe options that simctl cannot honour. `--scale 1.0` matches simctl's native size and is
    /// accepted; `nil` means the option was not passed.
    static func unsupportedOptions(fps: Int?, quality: Int?, scale: Double?) -> [String] {
        var options: [String] = []
        if fps != nil {
            options.append("--fps")
        }
        if quality != nil {
            options.append("--quality")
        }
        if let scale, scale != 1.0 {
            options.append("--scale")
        }
        return options
    }

    static func unsupportedOptionsError(display: String, options: [String]) -> CLIError {
        CLIError(
            errorDescription: "record-video records display \(display) with `xcrun simctl io recordVideo`, which records H.264 at the display's native size and refresh and cannot honour \(options.joined(separator: ", ")). Remove \(options.count == 1 ? "it" : "them") to record this display."
        )
    }

    enum Finalization: Equatable {
        /// simctl exited 0 and wrote a non-empty file.
        case saved
        /// simctl did not exit within the finalisation timeout.
        case timedOut
        /// simctl exited with a non-zero status.
        case failed(status: Int32)
        /// simctl exited 0 without writing the file.
        case missingFile
        /// simctl exited 0 and left an empty file.
        case emptyFile
    }

    /// Classifies the end of a recording.
    ///
    /// - Parameters:
    ///   - terminationStatus: simctl's exit status, `nil` when it was still running at the deadline.
    ///   - outputFileSize: size of the recorded file, `nil` when it does not exist.
    static func finalization(terminationStatus: Int32?, outputFileSize: Int?) -> Finalization {
        guard let terminationStatus else {
            return .timedOut
        }
        guard terminationStatus == 0 else {
            return .failed(status: terminationStatus)
        }
        guard let outputFileSize else {
            return .missingFile
        }
        return outputFileSize > 0 ? .saved : .emptyFile
    }

    /// Records until `cancellationFlag` is set, then stops simctl with SIGINT and waits for the file.
    ///
    /// simctl runs in AXe's process group, so a terminal Ctrl+C reaches it as well; a second
    /// cancellation while simctl finalises escalates to SIGTERM. simctl writes a QuickTime movie.
    /// Unless `outputURL` ends in `.mov`, AXe records to a temporary `.mov` beside it and remuxes it
    /// to MP4 without re-encoding.
    ///
    /// - Parameters:
    ///   - executableURL: `xcrun`; tests inject a stand-in.
    ///   - leadingArguments: arguments placed before the simctl arguments (tests only).
    ///   - warn: receives warnings; defaults to stderr.
    static func record(
        simulatorUDID: String,
        display: String,
        outputURL: URL,
        cancellationFlag: CancellationFlag,
        executableURL: URL = xcrunURL,
        leadingArguments: [String] = [],
        startTimeout: TimeInterval = startTimeout,
        finalizeTimeout: TimeInterval = finalizeTimeout,
        warn: (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
    ) async throws {
        let directoryURL = outputURL.deletingLastPathComponent()
        for staleURL in removeStaleRecordings(in: directoryURL) {
            warn("Removed a stale temporary recording left by an earlier AXe run: \(staleURL.path)")
        }

        let keepsQuickTime = outputURL.pathExtension.lowercased() == "mov"
        let recordingURL = keepsQuickTime
            ? outputURL
            : directoryURL.appendingPathComponent("\(temporaryRecordingPrefix)\(UUID().uuidString).mov")
        defer {
            if !keepsQuickTime {
                try? FileManager.default.removeItem(at: recordingURL)
            }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let output = PipeCollector(outputPipe.fileHandleForReading)
        let errors = PipeCollector(errorPipe.fileHandleForReading)
        defer {
            output.stop()
            errors.stop()
        }

        let process = try SpawnedProcess(
            executableURL: executableURL,
            arguments: leadingArguments + arguments(simulatorUDID: simulatorUDID, display: display, outputPath: recordingURL.path),
            standardOutput: outputPipe.fileHandleForWriting.fileDescriptor,
            standardError: errorPipe.fileHandleForWriting.fileDescriptor
        )
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        // A failure below must not leave simctl recording in the background.
        defer { process.stop() }

        /// Waits up to 0.5 s for simctl's output to reach EOF, then summarises it.
        func failureDetail() async -> String {
            let drainDeadline = Date().addingTimeInterval(0.5)
            while !process.isRunning, !(output.isFinished && errors.isFinished), Date() < drainDeadline {
                await pause(milliseconds: 5)
            }
            return XcrunFailureDetail.summary(standardOutput: output.data, standardError: errors.data)
        }
        func markerSeen() -> Bool {
            String(decoding: errors.data, as: UTF8.self).contains(recordingStartedMarker)
        }
        func isCancelled() async -> Bool {
            await cancellationFlag.isCancelled()
        }

        // Wait for the first frame even when cancelled meanwhile, so a quick Ctrl+C still produces a
        // playable file.
        let startDeadline = Date().addingTimeInterval(startTimeout)
        while process.isRunning, !markerSeen(), Date() < startDeadline {
            await pause(milliseconds: 50)
        }
        if !process.isRunning, !markerSeen() {
            if await isCancelled() {
                throw CLIError(
                    errorDescription: "Recording of display \(display) stopped before simctl started recording; no file was written."
                )
            }
            throw simctlError(display: display, simulatorUDID: simulatorUDID, detail: await failureDetail(), status: process.terminationStatus ?? -1)
        }
        if process.isRunning, !markerSeen() {
            let detail = XcrunFailureDetail.summary(standardOutput: output.data, standardError: errors.data)
            warn("Warning: simctl did not report \"\(recordingStartedMarker)\" within \(Int(startTimeout)) seconds; recording anyway" + (detail.isEmpty ? "." : " (simctl: \(detail))."))
        }

        while process.isRunning, !(await isCancelled()) {
            await pause(milliseconds: 100)
        }

        let cancelledByCaller = await isCancelled()
        let stoppedBeforeRequest = !process.isRunning && !cancelledByCaller
        if process.isRunning {
            process.signal(SIGINT)
            let finalizeDeadline = Date().addingTimeInterval(finalizeTimeout)
            var escalated = false
            while process.isRunning, Date() < finalizeDeadline {
                if !escalated, await cancellationFlag.cancellationCount() >= 2 {
                    escalated = true
                    warn("Stopping simctl without waiting for it to finish the file.")
                    process.signal(SIGTERM)
                }
                await pause(milliseconds: 50)
            }
        }
        let terminationStatus = process.terminationStatus

        let outcome = finalization(terminationStatus: terminationStatus, outputFileSize: fileSize(at: recordingURL))
        if stoppedBeforeRequest, outcome != .saved {
            // simctl ended on its own (for example the simulator shut down); a clean exit with a file
            // is kept, since a terminal Ctrl+C reaches simctl before AXe notices it.
            let detail = await failureDetail()
            throw simctlError(
                display: display,
                simulatorUDID: simulatorUDID,
                detail: "simctl stopped recording before AXe asked it to" + (detail.isEmpty ? "" : ": \(detail)"),
                status: terminationStatus ?? -1
            )
        }
        switch outcome {
        case .saved:
            break
        case .timedOut:
            throw CLIError(
                errorDescription: "simctl did not finish writing the recording of display \(display) within \(Int(finalizeTimeout)) seconds after it was stopped."
            )
        case .failed(let status):
            throw simctlError(display: display, simulatorUDID: simulatorUDID, detail: await failureDetail(), status: status)
        case .missingFile:
            throw CLIError(errorDescription: "simctl exited without writing a recording of display \(display).")
        case .emptyFile:
            throw CLIError(errorDescription: "simctl wrote an empty recording of display \(display).")
        }

        if !keepsQuickTime {
            try await remuxToMP4(from: recordingURL, to: outputURL)
        }
    }

    /// Removes `.axe-recording-*.mov` files older than `maximumAge` from `directoryURL` and returns
    /// them. They are left behind only when AXe dies before its cleanup runs.
    @discardableResult
    static func removeStaleRecordings(
        in directoryURL: URL,
        maximumAge: TimeInterval = staleRecordingAge,
        now: Date = Date()
    ) -> [URL] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return []
        }
        var removed: [URL] = []
        for name in names where name.hasPrefix(temporaryRecordingPrefix) && name.hasSuffix(".mov") {
            let url = directoryURL.appendingPathComponent(name)
            guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > maximumAge,
                  (try? fileManager.removeItem(at: url)) != nil else {
                continue
            }
            removed.append(url)
        }
        return removed
    }

    /// Copies the QuickTime movie's tracks into an MP4 container without re-encoding.
    static func remuxToMP4(from sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CLIError(errorDescription: "AXe could not prepare the MP4 conversion of the recording.")
        }
        if #available(macOS 15.0, *) {
            try await session.export(to: destinationURL, as: .mp4)
        } else {
            session.outputURL = destinationURL
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else {
                throw CLIError(
                    errorDescription: "AXe could not convert the recording to MP4: \(session.error?.localizedDescription ?? "unknown error")"
                )
            }
        }
    }

    static func fileSize(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    /// Sleeps without spinning; a cancelled task falls back to a short blocking sleep.
    private static func pause(milliseconds: Int) async {
        if Task.isCancelled {
            usleep(useconds_t(milliseconds * 1_000))
        } else {
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
    }

    private static func simctlError(display: String, simulatorUDID: String, detail: String, status: Int32) -> CLIError {
        CLIError(
            errorDescription: "simctl could not record display \(display) of simulator \(simulatorUDID) (exit status \(status))" + (detail.isEmpty ? "." : ": \(detail)")
        )
    }
}

/// A child process started with `posix_spawn` in AXe's process group, with SIGINT and SIGTERM at
/// their default dispositions and an empty signal mask.
///
/// Foundation's `Process` puts the child in a new process group, so a terminal Ctrl+C or a signal
/// to AXe's group would not reach it, and it inherits the SIG_IGN that `SignalObserver` installs.
final class SpawnedProcess {
    let processIdentifier: pid_t
    private var exitStatus: Int32?

    init(executableURL: URL, arguments: [String], standardOutput: Int32, standardError: Int32) throws {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, standardOutput, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, standardError, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGTERM)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        posix_spawnattr_setsigmask(&attributes, &signalMask)
        // POSIX_SPAWN_CLOEXEC_DEFAULT: the child gets only stdin, stdout and stderr.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        let argv: [UnsafeMutablePointer<CChar>?] = ([executableURL.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executableURL.path, &fileActions, &attributes, argv, environ)
        guard result == 0 else {
            throw CLIError(errorDescription: "AXe could not start \(executableURL.path): \(String(cString: strerror(result)))")
        }
        processIdentifier = pid
    }

    var isRunning: Bool {
        terminationStatus == nil
    }

    /// The exit status (128 + signal for a signalled exit); `nil` while running. Reaps the child.
    var terminationStatus: Int32? {
        if let exitStatus {
            return exitStatus
        }
        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier {
            exitStatus = Self.exitStatus(fromWaitStatus: status)
        } else if result == -1, errno == ECHILD {
            exitStatus = -1
        }
        return exitStatus
    }

    func signal(_ signal: Int32) {
        guard isRunning else { return }
        kill(processIdentifier, signal)
    }

    /// Sends SIGTERM, then SIGKILL after 0.5 s, and waits up to 1 s more for the exit.
    func stop() {
        guard isRunning else { return }
        signal(SIGTERM)
        let terminateDeadline = Date().addingTimeInterval(0.5)
        while isRunning, Date() < terminateDeadline {
            usleep(10_000)
        }
        guard isRunning else { return }
        signal(SIGKILL)
        let killDeadline = Date().addingTimeInterval(1)
        while isRunning, Date() < killDeadline {
            usleep(10_000)
        }
    }

    /// Decodes a `waitpid` status: the exit code, or 128 + the signal number.
    static func exitStatus(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
