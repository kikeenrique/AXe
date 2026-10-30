import CryptoKit
import Darwin
import Foundation

/// The in-simulator helper (`Resources/sim-helper/axe-sim-helper.m`) that sends Device Hub's hinge
/// and orientation events and reads the hinge angle.
///
/// The helper is compiled on first use with the selected Xcode's iphonesimulator SDK, ad-hoc
/// signed, and cached under `~/Library/Caches/AXe/sim-helper/<key>/`. The key covers the source,
/// the developer directory, the Xcode build, the architecture and the compile flags, so a new AXe
/// release or a different or updated Xcode builds a fresh copy. `AXE_SIM_HELPER_PATH` points AXe
/// at a prebuilt helper instead.
enum SimHelper {
    static let executableName = "axe-sim-helper"
    static let signingIdentifier = "com.cameroncooke.axe.sim-helper"
    static let pathEnvironmentKey = "AXE_SIM_HELPER_PATH"
    static let buildTimeout: TimeInterval = 120
    static let defaultRunTimeout: TimeInterval = 10

    @MainActor private static var resolvedPath: URL?

    // MARK: Pure helpers

    /// Cache directory name: the first 12 hex digits of SHA-256 over the source, the developer
    /// directory, the Xcode build, the architecture and the compile flags, separated by NUL bytes.
    static func cacheKey(
        source: Data,
        developerDirectory: String,
        xcodeBuild: String,
        architecture: String,
        compileFlags: String
    ) -> String {
        var input = source
        for part in [developerDirectory, xcodeBuild, architecture, compileFlags] {
            input.append(0)
            input.append(Data(part.utf8))
        }
        let digest = SHA256.hash(data: input)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// `arm64` on Apple silicon (also when AXe itself runs under Rosetta, since the simulator
    /// runtime is arm64 there), `x86_64` otherwise.
    static func architecture(isAppleSilicon: Bool) -> String {
        isAppleSilicon ? "arm64" : "x86_64"
    }

    static func hostIsAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            return false
        }
        return value == 1
    }

    static func compileArguments(source: String, output: String, architecture: String) -> [String] {
        [
            "-sdk", "iphonesimulator", "clang",
            "-fobjc-arc", "-O2",
            "-arch", architecture,
            "-mios-simulator-version-min=17.0",
            "-framework", "Foundation",
            "-framework", "IOKit",
            "-framework", "CoreMotion",
            source,
            "-o", output,
        ]
    }

    /// The compile flags without the source and output paths, for the cache key.
    static func compileFlags(architecture: String) -> String {
        compileArguments(source: "<source>", output: "<output>", architecture: architecture).joined(separator: " ")
    }

    /// The Xcode build of a developer directory: `DTXcodeBuild` from `Contents/Info.plist`, else
    /// `ProductBuildVersion` from `Contents/version.plist`, else `unknown` (Command Line Tools).
    static func xcodeBuild(developerDirectory: String) -> String {
        let contents = URL(fileURLWithPath: developerDirectory, isDirectory: true).deletingLastPathComponent()
        let candidates = [
            (contents.appendingPathComponent("Info.plist"), "DTXcodeBuild"),
            (contents.appendingPathComponent("version.plist"), "ProductBuildVersion"),
        ]
        for (url, key) in candidates {
            if let dictionary = NSDictionary(contentsOf: url), let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return "unknown"
    }

    /// The most useful line of a failed clang run: the first line with `error:`, else the first non-empty line.
    static func compileFailureDetail(standardError: Data) -> String {
        let lines = String(decoding: standardError, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first(where: { $0.contains("error:") }) ?? lines.first ?? ""
    }

    /// The helper named by `AXE_SIM_HELPER_PATH`, or `nil` when it is unset.
    static func overrideURL(environment: [String: String]) throws -> URL? {
        guard let value = environment[pathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CLIError(errorDescription: "\(pathEnvironmentKey) points to \(url.path), which is not an executable file.")
        }
        return url
    }

    /// Moves a finished build into place. rename(2) replaces atomically, so a concurrent build of
    /// the same key cannot leave a partial file at `destination`.
    static func install(staging: URL, at destination: URL) throws {
        guard rename(staging.path, destination.path) == 0 else {
            let reason = String(cString: strerror(errno))
            throw CLIError(errorDescription: "AXe could not install the simulator helper at \(destination.path): \(reason)")
        }
    }

    /// Arguments for `simctl spawn`: the helper exits on its own after `timeout`, so a timed-out
    /// `simctl spawn` does not leave it running inside the simulator.
    static func spawnArguments(_ arguments: [String], timeout: TimeInterval) -> [String] {
        ["--deadline", String(Int(timeout.rounded(.up)))] + arguments
    }

    static func cacheRoot(fileManager: FileManager = .default) throws -> URL {
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return caches
            .appendingPathComponent("AXe", isDirectory: true)
            .appendingPathComponent("sim-helper", isDirectory: true)
    }

    static func bundledSourceURL() -> URL? {
        Bundle.module.url(forResource: executableName, withExtension: "m", subdirectory: "sim-helper")
    }

    // MARK: Build

    /// Returns the helper executable, building it when the cache has no copy for this source and Xcode.
    @MainActor
    static func executableURL(logger: AxeLogger) async throws -> URL {
        if let resolvedPath {
            return resolvedPath
        }
        if let override = try overrideURL(environment: ProcessInfo.processInfo.environment) {
            resolvedPath = override
            return override
        }

        guard let sourceURL = bundledSourceURL() else {
            throw CLIError(errorDescription: "The bundled simulator helper source was not found. Reinstall AXe.")
        }
        let source = try Data(contentsOf: sourceURL)
        let developerDirectory = try await selectedDeveloperDirectory()
        let architecture = architecture(isAppleSilicon: hostIsAppleSilicon())
        let key = cacheKey(
            source: source,
            developerDirectory: developerDirectory,
            xcodeBuild: xcodeBuild(developerDirectory: developerDirectory),
            architecture: architecture,
            compileFlags: compileFlags(architecture: architecture)
        )
        let directory = try cacheRoot().appendingPathComponent(key, isDirectory: true)
        let executable = directory.appendingPathComponent(executableName)

        if FileManager.default.isExecutableFile(atPath: executable.path) {
            logger.info().log("Using cached simulator helper \(executable.path)")
            resolvedPath = executable
            return executable
        }

        logger.info().log("Building simulator helper for \(architecture) into \(directory.path)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent("\(executableName).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }

        let compile = try await XcrunProcess.run(
            compileArguments(source: sourceURL.path, output: staging.path, architecture: architecture),
            timeout: buildTimeout
        )
        guard compile.status == 0 else {
            throw buildError("compile", detail: compileFailureDetail(standardError: compile.standardError))
        }

        let sign = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-f", "-s", "-", "-i", signingIdentifier, staging.path],
            timeout: 30,
            displayName: "codesign"
        )
        guard sign.status == 0 else {
            throw buildError("sign", detail: sign.failureDetail)
        }

        try install(staging: staging, at: executable)
        resolvedPath = executable
        return executable
    }

    private static func selectedDeveloperDirectory() async throws -> String {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            arguments: ["-p"],
            timeout: 10,
            displayName: "xcode-select"
        )
        let path = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !path.isEmpty else {
            throw CLIError(errorDescription: "AXe could not read the selected Xcode with `xcode-select -p`. Select Xcode with `xcode-select -s` and try again.")
        }
        return path
    }

    private static func buildError(_ step: String, detail: String) -> CLIError {
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        return CLIError(
            errorDescription: "AXe could not \(step) the simulator helper\(suffix). Foldable support needs Xcode 27.1 or later with the iOS Simulator SDK; check `xcode-select -p`."
        )
    }

    // MARK: Run

    /// Runs the helper inside the simulator with `xcrun simctl spawn`.
    @MainActor
    static func run(
        _ arguments: [String],
        simulatorUDID: String,
        timeout: TimeInterval = defaultRunTimeout,
        logger: AxeLogger
    ) async throws -> ProcessResult {
        let executable = try await executableURL(logger: logger)
        logger.info().log("Simulator helper: \(arguments.joined(separator: " "))")
        return try await XcrunProcess.run(
            ["simctl", "spawn", simulatorUDID, executable.path] + spawnArguments(arguments, timeout: timeout),
            timeout: timeout
        )
    }

    /// Runs the helper and throws when it exits non-zero.
    @MainActor
    @discardableResult
    static func runChecked(
        _ arguments: [String],
        simulatorUDID: String,
        timeout: TimeInterval = defaultRunTimeout,
        logger: AxeLogger
    ) async throws -> ProcessResult {
        let result = try await run(arguments, simulatorUDID: simulatorUDID, timeout: timeout, logger: logger)
        guard result.status == 0 else {
            let detail = failureMessage(result)
            throw CLIError(
                errorDescription: "The simulator helper failed running `\(arguments.joined(separator: " "))` in simulator \(simulatorUDID)" + (detail.isEmpty ? "." : ": \(detail)")
            )
        }
        return result
    }

    /// The helper's own message without its `axe-sim-helper:` prefix, or the xcrun failure detail.
    static func failureMessage(_ result: ProcessResult) -> String {
        let prefix = "\(executableName):"
        let lines = String(decoding: result.standardError, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.hasPrefix(prefix) }) {
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return result.failureDetail
    }
}
