import Foundation

/// A simulator platform the watchOS and tvOS E2E suites run against.
enum E2EPlatform: String {
    case watchOS
    case tvOS

    /// Environment variable that names the simulator to test explicitly.
    var udidEnvironmentKey: String {
        switch self {
        case .watchOS: return "AXE_WATCHOS_SIMULATOR_UDID"
        case .tvOS: return "AXE_TVOS_SIMULATOR_UDID"
        }
    }

    /// The system Settings app, present on every runtime of the platform.
    var settingsBundleID: String {
        switch self {
        case .watchOS: return "com.apple.NanoSettings"
        case .tvOS: return "com.apple.TVSettings"
        }
    }
}

/// One `axe list-simulators` line: `UDID | name | state | model | OS '…' | Platform '…'`.
struct ListedSimulator {
    let udid: String
    let state: String
    let platform: String

    init?(line: String) {
        let fields = line.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3,
              UUID(uuidString: fields[0]) != nil,
              let last = fields.last,
              last.hasPrefix("Platform '"), last.hasSuffix("'") else {
            return nil
        }
        udid = fields[0]
        state = fields[2]
        platform = String(last.dropFirst("Platform '".count).dropLast())
    }
}

extension TestHelpers {
    /// The simulator for a platform suite: the UDID in the platform's environment variable, or else the only booted
    /// simulator of that platform. Other booted simulators (iOS, visionOS, a second watch) are never picked.
    static func requirePlatformSimulatorUDID(_ platform: E2EPlatform) async throws -> String {
        try requireE2EEnabled()
        let listing = try await CommandRunner.run("\(try getAxePath()) list-simulators")
        let simulators = listing.output
            .components(separatedBy: .newlines)
            .compactMap(ListedSimulator.init(line:))

        if let requested = ProcessInfo.processInfo.environment[platform.udidEnvironmentKey], !requested.isEmpty {
            guard let simulator = simulators.first(where: { $0.udid.caseInsensitiveCompare(requested) == .orderedSame }) else {
                throw TestError.commandError("\(platform.udidEnvironmentKey)=\(requested) is not a known simulator.")
            }
            guard simulator.platform == platform.rawValue else {
                throw TestError.commandError(
                    "\(platform.udidEnvironmentKey) names a \(simulator.platform) simulator, not \(platform.rawValue)."
                )
            }
            guard simulator.state == "Booted" else {
                throw TestError.commandError("\(platform.udidEnvironmentKey) names a simulator that is not booted.")
            }
            return simulator.udid
        }

        let booted = simulators.filter { $0.platform == platform.rawValue && $0.state == "Booted" }
        guard booted.count == 1, let simulator = booted.first else {
            throw TestError.commandError(
                "Found \(booted.count) booted \(platform.rawValue) simulators; boot exactly one or set \(platform.udidEnvironmentKey)."
            )
        }
        return simulator.udid
    }

    /// Every root `describe-ui` reports, decoded.
    static func describeUIRoots(simulatorUDID: String, arguments: String = "") async throws -> [UIElement] {
        let command = arguments.isEmpty ? "describe-ui" : "describe-ui \(arguments)"
        let result = try await runAxeCommand(command, simulatorUDID: simulatorUDID)
        return try UIStateParser.parseDescribeUIRoots(result.output)
    }

    /// The roots and all their descendants, depth first.
    static func flattened(_ roots: [UIElement]) -> [UIElement] {
        roots.flatMap { root in [root] + flattened(root.children ?? []) }
    }

    /// Relaunches a system app from scratch and waits until its process owns the frontmost application root and
    /// `isReady` accepts the tree. The app is terminated first and then launched: on tvOS
    /// `simctl launch --terminate-running-process` can leave the home screen in front.
    @discardableResult
    static func relaunchSystemApp(
        _ bundleID: String,
        simulatorUDID: String,
        timeout: TimeInterval = 20,
        isReady: ([UIElement]) -> Bool
    ) async throws -> [UIElement] {
        do {
            return try await launchSystemAppOnce(bundleID, simulatorUDID: simulatorUDID, timeout: timeout, isReady: isReady)
        } catch {
            print("Retrying the launch of \(bundleID): \(error)")
            return try await launchSystemAppOnce(bundleID, simulatorUDID: simulatorUDID, timeout: timeout, isReady: isReady)
        }
    }

    private static func launchSystemAppOnce(
        _ bundleID: String,
        simulatorUDID: String,
        timeout: TimeInterval,
        isReady: ([UIElement]) -> Bool
    ) async throws -> [UIElement] {
        _ = try await CommandRunner.run("xcrun simctl terminate \(simulatorUDID) \(bundleID)", allowFailure: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        // A watchOS launch occasionally hangs; a short timeout lets the caller's retry start sooner.
        let launch = try await CommandRunner.run("xcrun simctl launch \(simulatorUDID) \(bundleID)", timeout: 15)
        // simctl prints `<bundle id>: <pid>`.
        guard let pid = launch.output
            .components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("\(bundleID):") })
            .flatMap({ Int($0.dropFirst(bundleID.count + 1).trimmingCharacters(in: .whitespaces)) }) else {
            throw TestError.unexpectedState("simctl launch printed no process ID for \(bundleID): \(launch.output)")
        }
        return try await waitForTree(
            simulatorUDID: simulatorUDID,
            timeout: timeout,
            description: "\(bundleID) (pid \(pid)) to come to the front"
        ) { roots in
            roots.contains { $0.type == "Application" && $0.pid == pid } && isReady(roots)
        }
    }

    /// Polls `describe-ui` until `condition` accepts the tree. Read failures while an app launches are retried.
    @discardableResult
    static func waitForTree(
        simulatorUDID: String,
        timeout: TimeInterval,
        description: String,
        until condition: ([UIElement]) -> Bool
    ) async throws -> [UIElement] {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLabels: [String] = []
        var lastError: Error?
        while Date() < deadline {
            do {
                let roots = try await describeUIRoots(simulatorUDID: simulatorUDID)
                if condition(roots) {
                    return roots
                }
                lastLabels = flattened(roots).compactMap(\.label)
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let errorDetail = lastError.map { " Last error: \($0.localizedDescription)" } ?? ""
        throw TestError.unexpectedState(
            "Timed out waiting for \(description). Last labels: \(lastLabels.prefix(30)).\(errorDetail)"
        )
    }

    /// The element `describe-ui --focused` prints.
    static func focusedElement(simulatorUDID: String) async throws -> UIElement {
        let roots = try await describeUIRoots(simulatorUDID: simulatorUDID, arguments: "--focused")
        guard let element = roots.first else {
            throw TestError.elementNotFound("describe-ui --focused printed no element")
        }
        return element
    }

    /// Polls `describe-ui --focused` until `condition` accepts the focused element.
    @discardableResult
    static func waitForFocus(
        simulatorUDID: String,
        timeout: TimeInterval = 5,
        description: String,
        until condition: (UIElement) -> Bool
    ) async throws -> UIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLabel: String?
        while Date() < deadline {
            if let element = try? await focusedElement(simulatorUDID: simulatorUDID) {
                if condition(element) {
                    return element
                }
                lastLabel = element.label
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw TestError.unexpectedState("Timed out waiting for \(description). Last focused label: \(lastLabel ?? "none")")
    }

    /// Labels and frames of the labelled elements, frames rounded to a quarter point: what a settled screen keeps.
    static func layoutSignature(_ roots: [UIElement]) -> [String] {
        func rounded(_ value: Double) -> Double { (value * 4).rounded() / 4 }
        return flattened(roots).compactMap { element in
            guard let label = element.label, let frame = element.frame else { return nil }
            return "\(element.type)|\(label)|\(rounded(frame.x)),\(rounded(frame.y)),\(rounded(frame.width)),\(rounded(frame.height))"
        }
    }

    /// Single-quotes `value` for the `/bin/bash -c` line `runAxeCommand` builds.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Directory for files the suites write: `AXE_E2E_ARTIFACTS_DIR` when set, else the system temporary directory.
    static func e2eArtifactsDirectory() throws -> URL {
        let directory: URL
        if let configured = ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACTS_DIR"], !configured.isEmpty {
            directory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Width and height from a PNG's IHDR chunk, or nil when `data` is not a PNG.
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, Array(bytes[0..<8]) == signature, Array(bytes[12..<16]) == Array("IHDR".utf8) else {
            return nil
        }
        func bigEndian(_ range: Range<Int>) -> Int {
            bytes[range].reduce(0) { ($0 << 8) | Int($1) }
        }
        return (bigEndian(16..<20), bigEndian(20..<24))
    }
}
