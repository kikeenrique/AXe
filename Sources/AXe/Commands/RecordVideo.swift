import ArgumentParser
import Foundation
import FBSimulatorControl
import FBSimulatorVideo
import FBVideoCore
@preconcurrency import FBControlCore

struct RecordVideo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the simulator display to an MP4 file using H.264 encoding"
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Option(help: "Frames per second (1-30, default: 10)")
    var fps: Int = 10

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0

    @Option(help: "Output MP4 file path. Defaults to axe-video-<timestamp>.mp4 in the current directory.")
    var output: String?

    func validate() throws {
        guard fps >= 1 && fps <= 30 else {
            throw ValidationError("FPS must be between 1 and 30")
        }

        guard quality >= 1 && quality <= 100 else {
            throw ValidationError("Quality must be between 1 and 100")
        }

        guard scale >= 0.1 && scale <= 1.0 else {
            throw ValidationError("Scale must be between 0.1 and 1.0")
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let trimmedUDID = simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUDID.isEmpty else {
            throw CLIError(errorDescription: "Simulator UDID cannot be empty. Use --udid to specify a simulator.")
        }

        guard let targetSimulator = try await SimulatorSession.simulator(udid: trimmedUDID, logger: logger) else {
            throw CLIError(errorDescription: "Simulator with UDID \(trimmedUDID) not found.")
        }

        guard targetSimulator.state == .booted else {
            throw CLIError(errorDescription: "Simulator \(trimmedUDID) is not booted. Current state: \(targetSimulator.stateString.rawValue)")
        }

        let outputURL = try prepareOutputURL()
        FileHandle.standardError.write(Data("Recording simulator \(targetSimulator.udid) to \(outputURL.path)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop recording\n".utf8))

        let cancellationFlag = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            Task {
                await cancellationFlag.cancel()
            }
        }
        defer { signalObserver.invalidate() }

        do {
            try await recordVideo(
                simulator: targetSimulator,
                outputURL: outputURL,
                fps: fps,
                quality: quality,
                scale: scale,
                cancellationFlag: cancellationFlag
            )
            FileHandle.standardError.write(Data("Recording saved to \(outputURL.path)\n".utf8))
            print(outputURL.path)
        } catch {
            throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)")
        }
    }

    /// Records the active display with IDB's in-process H.264 recorder, which muxes an MP4 at a
    /// constant frame rate. `quality` maps to the encoder's quality target (0-1).
    private func recordVideo(
        simulator: Simulator,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws {
        let configuration = VideoStreamConfiguration(
            format: .compressedVideo(withCodec: .h264, transport: .annexB),
            framesPerSecond: fps,
            rateControl: .quality(Double(quality) / 100.0),
            scaleFactor: scale,
            keyFrameRate: nil,
            display: .active
        )
        // `SimulatorVideo` directly rather than `simulator.videoRecording`, whose handle offers only
        // `stop()`: `startedAt()` tells whether the encoder has muxed a frame, so a framebuffer or
        // encoder failure is reported now instead of when the user stops the recording.
        let framebuffer = try await simulator.framebuffer.connect(display: .active)
        let recording = SimulatorVideo(
            framebuffer: framebuffer,
            configuration: configuration,
            filePath: outputURL.path,
            logger: simulator.logger
        )
        try await recording.startRecording()

        let startTime = Date()
        var lastLoggedSecond = 0
        var hasFirstFrame = false

        while !Task.isCancelled, await !cancellationFlag.isCancelled() {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                break
            }
            let elapsed = Date().timeIntervalSince(startTime)
            if !hasFirstFrame {
                hasFirstFrame = await recording.startedAt() != nil
                if !hasFirstFrame {
                    guard elapsed < Self.firstFrameTimeout else {
                        _ = try? await recording.stop()
                        try? FileManager.default.removeItem(at: outputURL)
                        throw CLIError(
                            errorDescription: "The recording produced no frame within \(Int(Self.firstFrameTimeout)) seconds; the simulator framebuffer or the H.264 encoder did not start. No file was written."
                        )
                    }
                    continue
                }
            }
            let elapsedSeconds = Int(elapsed)
            if elapsedSeconds > lastLoggedSecond {
                lastLoggedSecond = elapsedSeconds
                FileHandle.standardError.write(Data("Recording... \(elapsedSeconds)s\n".utf8))
            }
        }

        _ = try await recording.stop()
    }

    /// How long the in-process recorder may take to mux its first frame before AXe reports failure.
    /// The eager cadence pushes a frame per tick even while the screen is still.
    static let firstFrameTimeout: TimeInterval = 5

    private func prepareOutputURL() throws -> URL {
        let fileManager = FileManager.default
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let providedPath = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
        } else {
            resolvedPath = "axe-video-\(formatter.string(from: Date())).mp4"
        }

        let baseURL: URL
        if resolvedPath.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: resolvedPath)
        } else {
            baseURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let filename = "axe-video-\(formatter.string(from: Date())).mp4"
            let directoryURL = baseURL
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            }
            return directoryURL.appendingPathComponent(filename)
        }

        let directoryURL = baseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        if fileManager.fileExists(atPath: baseURL.path) {
            var existingIsDirectory: ObjCBool = false
            fileManager.fileExists(atPath: baseURL.path, isDirectory: &existingIsDirectory)
            if existingIsDirectory.boolValue {
                throw CLIError(errorDescription: "Output path \(baseURL.path) is a directory. Provide a file name or point to a different location.")
            }
            try fileManager.removeItem(at: baseURL)
        }

        return baseURL
    }
}
