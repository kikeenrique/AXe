import Foundation
import Testing
@testable import AXe

// Unit tests for `record-video --display` and `stream-video --display`. Fixtures are the devicectl
// captures in Fixtures/devicectl (see SimulatorDisplaysTests.swift).

private func fixtureState(_ name: String) throws -> SimulatorDisplayState {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/devicectl")
    )
    return try SimulatorDisplayState.decode(from: Data(contentsOf: url))
}

private func errorMessage(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return error.localizedDescription
    }
}

@Suite("Video --display option parsing")
struct VideoDisplayOptionTests {
    @Test("record-video defaults to auto and leaves the idb options unset")
    func recordVideoDefaults() throws {
        let command = try RecordVideo.parse(["--udid", "SIMULATOR_UDID"])

        #expect(command.display == .auto)
        #expect(command.fps == nil)
        #expect(command.quality == nil)
        #expect(command.scale == nil)
    }

    @Test(
        "record-video parses --display",
        arguments: [
            ("cover", DisplaySelection.cover),
            ("inner", .inner),
            ("3", .id(3)),
            ("LCD-1", .name("LCD-1")),
        ]
    )
    func recordVideoParsesDisplay(raw: String, expected: DisplaySelection) throws {
        let command = try RecordVideo.parse(["--udid", "SIMULATOR_UDID", "--display", raw])

        #expect(command.display == expected)
    }

    @Test("record-video keeps explicit idb options")
    func recordVideoKeepsOptions() throws {
        let command = try RecordVideo.parse([
            "--udid", "SIMULATOR_UDID", "--fps", "5", "--quality", "60", "--scale", "0.5",
        ])

        #expect(command.fps == 5)
        #expect(command.quality == 60)
        #expect(command.scale == 0.5)
    }

    @Test(
        "record-video still validates idb option ranges",
        arguments: [["--fps", "40"], ["--quality", "0"], ["--scale", "2"], ["--display", ""]]
    )
    func recordVideoRejectsInvalidValues(arguments: [String]) {
        #expect(throws: (any Error).self) {
            try RecordVideo.parse(["--udid", "SIMULATOR_UDID"] + arguments)
        }
    }

    @Test("stream-video defaults to auto and parses --display")
    func streamVideoParsesDisplay() throws {
        #expect(try StreamVideo.parse(["--udid", "SIMULATOR_UDID"]).display == .auto)
        #expect(try StreamVideo.parse(["--udid", "SIMULATOR_UDID", "--display", "inner"]).display == .inner)
        #expect(try StreamVideo.parse(["--udid", "SIMULATOR_UDID", "--display", "3"]).display == .id(3))
        #expect(throws: (any Error).self) {
            try StreamVideo.parse(["--udid", "SIMULATOR_UDID", "--display", "-1"])
        }
    }
}

@Suite("record-video capture decision")
struct RecordVideoCaptureTests {
    @Test("A non-foldable with auto keeps the idb path")
    func nonFoldableAuto() throws {
        #expect(try DisplayCapture.resolve(selection: .auto, state: nil) == .framebuffer)
        #expect(try DisplayCapture.resolve(selection: .auto, state: fixtureState("single-display")) == .framebuffer)
    }

    @Test(
        "A foldable with auto records the active display with simctl",
        arguments: [("duo-folded", 1), ("duo-unfolded", 3)]
    )
    func foldableAuto(fixture: String, expectedID: Int) throws {
        let capture = try DisplayCapture.resolve(selection: .auto, state: fixtureState(fixture))

        guard case .display(let display) = capture else {
            Issue.record("Expected simctl, got \(capture)")
            return
        }
        #expect(display.displayId == expectedID)
    }

    @Test("An explicit ID or name records with simctl")
    func explicitDisplay() throws {
        #expect(try DisplayCapture.resolve(selection: .id(1), state: nil) == .unvalidatedDisplay("1"))
        #expect(try DisplayCapture.resolve(selection: .name("LCD"), state: nil) == .unvalidatedDisplay("LCD"))

        let state = try fixtureState("duo-folded")
        guard case .display(let display) = try DisplayCapture.resolve(selection: .name("LCD-1"), state: state) else {
            Issue.record("Expected a resolved display")
            return
        }
        #expect(display.displayId == 3)
    }

    @Test("cover and inner with the probe disabled name AXE_DISPLAY_PROBE", arguments: [DisplaySelection.cover, .inner])
    func probeDisabled(selection: DisplaySelection) {
        let message = errorMessage {
            _ = try DisplayCapture.resolve(selection: selection, state: nil, isFoldableWithProbeDisabled: true)
        }

        #expect(message?.contains("AXE_DISPLAY_PROBE=never") == true)
    }
}

@Suite("stream-video display decision")
struct StreamVideoCaptureTests {
    @Test("A non-foldable with auto streams the framebuffer")
    func nonFoldableAuto() throws {
        try StreamCapture.validate(selection: .auto, state: nil)
        try StreamCapture.validate(selection: .auto, state: fixtureState("single-display"))
        try StreamCapture.validate(selection: .id(1), state: fixtureState("single-display"))
    }

    @Test("A foldable with auto streams the active display", arguments: ["duo-folded", "duo-unfolded"])
    func foldableAuto(fixture: String) throws {
        try StreamCapture.validate(selection: .auto, state: fixtureState(fixture))
    }

    @Test(
        "A foldable streams the display it names when that display is active",
        arguments: [
            ("duo-folded", DisplaySelection.cover),
            ("duo-folded", .id(1)),
            ("duo-folded", .name("LCD")),
            ("duo-unfolded", .inner),
            ("duo-unfolded", .id(3)),
            ("duo-unfolded", .name("LCD-1")),
        ]
    )
    func foldableActive(fixture: String, selection: DisplaySelection) throws {
        try StreamCapture.validate(selection: selection, state: fixtureState(fixture))
    }

    @Test(
        "A foldable refuses an inactive display and points to record-video",
        arguments: [
            ("duo-folded", DisplaySelection.inner, 3),
            ("duo-folded", .id(3), 3),
            ("duo-unfolded", .cover, 1),
            ("duo-unfolded", .name("LCD"), 1),
        ]
    )
    func foldableInactive(fixture: String, selection: DisplaySelection, displayID: Int) throws {
        let state = try fixtureState(fixture)
        let message = errorMessage { try StreamCapture.validate(selection: selection, state: state) }

        let text = try #require(message)
        #expect(text.contains("is not active"))
        #expect(text.contains("record-video --display \(displayID)"))
    }

    @Test("Unknown displays fail")
    func unknownDisplay() throws {
        let state = try fixtureState("duo-unfolded")

        #expect(throws: CLIError.self) { try StreamCapture.validate(selection: .id(9), state: state) }
    }

    @Test("Without display state, explicit displays fail", arguments: [DisplaySelection.id(1), .name("LCD"), .cover, .inner])
    func noState(selection: DisplaySelection) {
        #expect(throws: CLIError.self) { try StreamCapture.validate(selection: selection, state: nil) }
    }

    @Test("cover and inner with the probe disabled name AXE_DISPLAY_PROBE", arguments: [DisplaySelection.cover, .inner])
    func probeDisabled(selection: DisplaySelection) {
        let message = errorMessage {
            try StreamCapture.validate(selection: selection, state: nil, isFoldableWithProbeDisabled: true)
        }

        #expect(message?.contains("AXE_DISPLAY_PROBE=never") == true)
    }
}

@Suite("simctl video recorder")
struct SimctlVideoRecorderTests {
    @Test("Builds the recordVideo arguments")
    func arguments() {
        let arguments = SimctlVideoRecorder.arguments(
            simulatorUDID: "SIMULATOR_UDID",
            display: "3",
            outputPath: "/path/to/recording.mov"
        )

        #expect(arguments == [
            "simctl", "io", "SIMULATOR_UDID", "recordVideo",
            "--codec=h264", "--display=3", "--force", "/path/to/recording.mov",
        ])
    }

    @Test(
        "Flags AXe options that simctl cannot honour",
        arguments: [
            (Int?.none, Int?.none, Double?.none, [String]()),
            (nil, nil, 1.0, []),
            (10, nil, nil, ["--fps"]),
            (nil, 80, nil, ["--quality"]),
            (nil, nil, 0.5, ["--scale"]),
            (5, 60, 0.5, ["--fps", "--quality", "--scale"]),
        ]
    )
    func unsupportedOptions(fps: Int?, quality: Int?, scale: Double?, expected: [String]) {
        #expect(SimctlVideoRecorder.unsupportedOptions(fps: fps, quality: quality, scale: scale) == expected)
    }

    @Test("The unsupported-option error names the display and every option")
    func unsupportedOptionsError() {
        let message = SimctlVideoRecorder.unsupportedOptionsError(display: "1", options: ["--fps", "--scale"]).localizedDescription

        #expect(message.contains("display 1"))
        #expect(message.contains("--fps, --scale"))
        #expect(message.contains("Remove them"))
    }

    @Test(
        "Classifies the end of a recording",
        arguments: [
            (Int32?.none, Int?.some(1_000), SimctlVideoRecorder.Finalization.timedOut),
            (0, 1_000, .saved),
            (0, 0, .emptyFile),
            (0, nil, .missingFile),
            (22, 1_000, .failed(status: 22)),
            (1, nil, .failed(status: 1)),
        ]
    )
    func finalization(status: Int32?, size: Int?, expected: SimctlVideoRecorder.Finalization) {
        #expect(SimctlVideoRecorder.finalization(terminationStatus: status, outputFileSize: size) == expected)
    }

    @Test("Decodes waitpid statuses")
    func exitStatusDecoding() {
        #expect(SpawnedProcess.exitStatus(fromWaitStatus: 0) == 0)
        #expect(SpawnedProcess.exitStatus(fromWaitStatus: 22 << 8) == 22)
        #expect(SpawnedProcess.exitStatus(fromWaitStatus: SIGINT) == 130)
    }

    @Test("Reads the recorded file size")
    func fileSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-video-size-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(SimctlVideoRecorder.fileSize(at: url) == nil)
        try Data(count: 12).write(to: url)
        #expect(SimctlVideoRecorder.fileSize(at: url) == 12)
    }

    @Test("Removes only stale temporary recordings")
    func removesStaleRecordings() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = directory.appendingPathComponent(".axe-recording-stale.mov")
        let fresh = directory.appendingPathComponent(".axe-recording-fresh.mov")
        let unrelated = directory.appendingPathComponent("movie.mov")
        for url in [stale, fresh, unrelated] {
            try Data(count: 4).write(to: url)
        }
        let old = Date().addingTimeInterval(-2 * SimctlVideoRecorder.staleRecordingAge)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: unrelated.path)

        let removed = SimctlVideoRecorder.removeStaleRecordings(in: directory)

        #expect(removed.map(\.lastPathComponent) == [stale.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}

/// Runs `SimctlVideoRecorder.record` against Fixtures/simctl/fake-record-video.sh.
@Suite("simctl video recorder lifecycle", .serialized)
struct SimctlVideoRecorderLifecycleTests {
    private struct Outcome {
        let error: String?
        let warnings: [String]
        let directoryContents: [String]
    }

    private func record(
        mode: String,
        markerDelay: Double = 0.1,
        outputName: String = "out.mov",
        cancelAfter: Duration?,
        startTimeout: TimeInterval = 2,
        directory: URL
    ) async throws -> Outcome {
        let script = try #require(
            Bundle.module.url(forResource: "fake-record-video", withExtension: "sh", subdirectory: "Fixtures/simctl")
        )
        let flag = CancellationFlag()
        if let cancelAfter {
            if cancelAfter == .zero {
                await flag.cancel()
            } else {
                Task {
                    try? await Task.sleep(for: cancelAfter)
                    await flag.cancel()
                }
            }
        }
        var warnings: [String] = []
        var message: String?
        do {
            try await SimctlVideoRecorder.record(
                simulatorUDID: "SIMULATOR_UDID",
                display: "1",
                outputURL: directory.appendingPathComponent(outputName),
                cancellationFlag: flag,
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                leadingArguments: [script.path, mode, String(markerDelay)],
                startTimeout: startTimeout,
                finalizeTimeout: 2,
                warn: { warnings.append($0) }
            )
        } catch {
            message = error.localizedDescription
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Outcome(error: message, warnings: warnings, directoryContents: contents.sorted())
    }

    @Test("Starts, stops on cancellation with SIGINT and keeps the file")
    func normalRecording() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = try await record(mode: "normal", cancelAfter: .milliseconds(400), directory: directory)

        #expect(outcome.error == nil)
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.directoryContents == ["out.mov"])
        let data = try Data(contentsOf: directory.appendingPathComponent("out.mov"))
        #expect(String(decoding: data, as: UTF8.self) == "fake movie data")
    }

    @Test("A cancellation before the marker still waits for it and finalises the file")
    func cancelBeforeMarker() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = try await record(mode: "normal", markerDelay: 0.4, cancelAfter: .zero, directory: directory)

        #expect(outcome.error == nil)
        #expect(SimctlVideoRecorder.fileSize(at: directory.appendingPathComponent("out.mov")) == 15)
    }

    @Test("Without the marker, recording continues after the start timeout with a warning")
    func markerTimeout() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = try await record(
            mode: "no-marker",
            cancelAfter: .milliseconds(700),
            startTimeout: 0.3,
            directory: directory
        )

        #expect(outcome.error == nil)
        #expect(outcome.warnings.count == 1)
        #expect(outcome.warnings.first?.contains("did not report \"Recording started\"") == true)
        #expect(outcome.warnings.first?.contains("Recording is warming up") == true)
        #expect(outcome.directoryContents == ["out.mov"])
    }

    @Test("An early simctl failure reports its error and removes the temporary file")
    func earlyExit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = try await record(mode: "early-exit", outputName: "out.mp4", cancelAfter: nil, directory: directory)

        let error = try #require(outcome.error)
        #expect(error.contains("exit status 22"))
        #expect(error.contains("Device does not have a '9' display port"))
        #expect(outcome.directoryContents.isEmpty)
    }

    @Test("simctl quitting after a Ctrl+C, before the marker, says no file was written")
    func quitAfterCancelBeforeMarker() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = try await record(mode: "quit", outputName: "out.mp4", cancelAfter: .zero, directory: directory)

        let error = try #require(outcome.error)
        #expect(error.contains("stopped before simctl started recording; no file was written"))
        #expect(!error.contains("exit status"))
        #expect(outcome.directoryContents.isEmpty)
    }

    @Test("A second cancellation while simctl finalises escalates to SIGTERM")
    func secondCancellationEscalates() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try #require(
            Bundle.module.url(forResource: "fake-record-video", withExtension: "sh", subdirectory: "Fixtures/simctl")
        )
        let flag = CancellationFlag()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await flag.cancel()
            try? await Task.sleep(for: .milliseconds(300))
            await flag.cancel()
        }
        var warnings: [String] = []
        let start = Date()

        await #expect(throws: CLIError.self) {
            try await SimctlVideoRecorder.record(
                simulatorUDID: "SIMULATOR_UDID",
                display: "1",
                outputURL: directory.appendingPathComponent("out.mp4"),
                cancellationFlag: flag,
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                leadingArguments: [script.path, "slow-stop", "0.1"],
                startTimeout: 2,
                finalizeTimeout: 5,
                warn: { warnings.append($0) }
            )
        }

        #expect(Date().timeIntervalSince(start) < 2)
        #expect(warnings == ["Stopping simctl without waiting for it to finish the file."])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)
    }

    @Test("simctl quitting on its own before the marker is a simctl failure")
    func quitWithoutCancellation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = try await record(mode: "quit", outputName: "out.mp4", cancelAfter: nil, directory: directory)

        #expect(outcome.error?.contains("exit status 2") == true)
        #expect(outcome.directoryContents.isEmpty)
    }
}

@Suite("Inactive display warning")
struct InactiveDisplayWarningTests {
    @Test("An explicit inactive display warns; auto and the active display do not")
    func warning() throws {
        let folded = try fixtureState("duo-folded")
        let inner = try #require(folded.innerDisplay)
        let cover = try #require(folded.coverDisplay)

        #expect(
            DisplayCapture.inactiveDisplayWarning(for: inner, selection: .id(3))
                == "Warning: display 3 (LCD-1) is not active; the capture may be black."
        )
        #expect(DisplayCapture.inactiveDisplayWarning(for: inner, selection: .inner) != nil)
        #expect(DisplayCapture.inactiveDisplayWarning(for: inner, selection: .auto) == nil)
        #expect(DisplayCapture.inactiveDisplayWarning(for: cover, selection: .cover) == nil)
    }
}

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("axe-video-recorder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
