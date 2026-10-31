import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Simulator Session

/// Process-wide owner of the IDB bootstrap and the `Simulator` objects AXe looks up.
///
/// Upstream `SimulatorSet` vends a new `Simulator` on every lookup and keeps none of them alive,
/// while its command objects (`hid`, `displays`, ...) hold the `Simulator` weakly. AXe therefore
/// keeps the bootstrap and one `Simulator` per UDID alive for the whole process, so the shared HID
/// connection and display tracker survive across the steps of a batch or a broker session.
@MainActor
enum SimulatorSession {
    private static var bootstrap: SimulatorControlBootstrap?
    private static var simulators: [String: Simulator] = [:]

    /// The bootstrap for the default device set, created on first use.
    static func control(logger: AxeLogger) throws -> SimulatorControlBootstrap {
        if let bootstrap {
            return bootstrap
        }
        // Some CoreSimulator mechanisms log through the global logger.
        ControlCoreGlobalConfiguration.defaultLogger = logger
        do {
            let created = try SimulatorControlBootstrap(
                configuration: SimulatorControlConfiguration(deviceSetPath: nil, logger: logger)
            )
            bootstrap = created
            return created
        } catch {
            logger.info().log("IDB simulator control failed to initialize: \(error.localizedDescription)")
            throw error
        }
    }

    /// Every available simulator in the default device set.
    static func allSimulators(logger: AxeLogger) throws -> [Simulator] {
        try control(logger: logger).set.allSimulators
    }

    /// The simulator with `udid`, or `nil` when the device set has no such available device.
    static func simulator(udid: String, logger: AxeLogger) throws -> Simulator? {
        if let cached = simulators[udid] {
            return cached
        }
        guard let simulator = try control(logger: logger).set.simulator(withUDID: udid) else {
            return nil
        }
        simulators[udid] = simulator
        return simulator
    }

    /// The platform of the simulator with `udid`; throws `CLIError.simulatorNotFound` when there is
    /// no such simulator. Use this before refusing a command for its platform.
    static func requirePlatform(udid: String, logger: AxeLogger) throws -> SimulatorPlatform {
        try PlatformSupport.resolvePlatform(udid: udid) {
            try simulator(udid: $0, logger: logger)?.platform
        }
    }

    /// The platform of the simulator with `udid`, from the cached `Simulator`'s configuration.
    /// `.unknown` when the simulator cannot be looked up, so coordinate and accessibility paths
    /// keep their iOS behaviour and report the lookup failure themselves. Never refuse a command
    /// on this value; use `requirePlatform(udid:logger:)` for that.
    static func platform(udid: String, logger: AxeLogger) -> SimulatorPlatform {
        guard let simulator = (try? simulator(udid: udid, logger: logger)) ?? nil else {
            return .unknown
        }
        return simulator.platform
    }

    /// The simulator with `udid`; throws `CLIError.simulatorNotFound` when it does not exist.
    static func requireSimulator(udid: String, logger: AxeLogger) throws -> Simulator {
        guard let simulator = try simulator(udid: udid, logger: logger) else {
            throw CLIError.simulatorNotFound(udid: udid)
        }
        return simulator
    }

    /// The simulator with `udid`; throws unless it exists and is booted.
    static func bootedSimulator(udid: String, logger: AxeLogger) throws -> Simulator {
        let simulator = try requireSimulator(udid: udid, logger: logger)
        guard simulator.state == .booted else {
            throw CLIError(
                errorDescription: "Simulator \(udid) is not booted. Current state: \(simulator.stateString.rawValue)."
            )
        }
        return simulator
    }
}

// MARK: - Bundled Resources

/// Locates the directory that holds IDB's `SimulatorFrameworkBridge-iOS` guest helper.
///
/// Upstream looks for `Resources/` beside the executable, which is the release and Homebrew
/// layout. A `swift build` binary lives in `.build/<config>/`, so AXe also accepts an explicit
/// directory (`AXE_IDB_BRIDGE_DIR`) and the checkout's `build_products/idb/bridge`.
enum IDBBridgeResources {
    static let environmentKey = "AXE_IDB_BRIDGE_DIR"
    static let bridgeName = "SimulatorFrameworkBridge-iOS"

    /// Picks the bridge directory, in order: `AXE_IDB_BRIDGE_DIR`, `Resources/` beside the
    /// executable, then `build_products/idb/bridge` in the nearest ancestor of the executable that
    /// contains `Package.swift`. Returns `nil` when none holds the bridge.
    ///
    /// - Parameter currentDirectory: resolves a relative `AXE_IDB_BRIDGE_DIR`.
    /// - Throws: when `AXE_IDB_BRIDGE_DIR` is set but does not contain the helper. The value would
    ///   otherwise replace IDB's own lookup and fail later with an upstream-worded error.
    static func resolveDirectory(
        environment: [String: String],
        executablePath: String?,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        fileExists: (String) -> Bool
    ) throws -> String? {
        if let explicit = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            let expanded = (explicit as NSString).expandingTildeInPath
            let directory = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded).standardizedFileURL
                : URL(fileURLWithPath: currentDirectory, isDirectory: true).appendingPathComponent(expanded).standardizedFileURL
            guard fileExists(directory.appendingPathComponent(bridgeName).path) else {
                throw CLIError(
                    errorDescription: "\(environmentKey) is set to '\(explicit)', but \(directory.path) does not contain \(bridgeName). Point it at the directory that holds the helper (the release's Resources/ or a checkout's build_products/idb/bridge), or unset it."
                )
            }
            return directory.path
        }
        guard let executablePath else { return nil }
        let executableDirectory = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let besideExecutable = executableDirectory.appendingPathComponent("Resources", isDirectory: true)
        if fileExists(besideExecutable.appendingPathComponent(bridgeName).path) {
            return besideExecutable.path
        }
        var directory = executableDirectory
        while directory.path != "/" && !directory.path.isEmpty {
            if fileExists(directory.appendingPathComponent("Package.swift").path) {
                let bridge = directory.appendingPathComponent("build_products/idb/bridge", isDirectory: true)
                if fileExists(bridge.appendingPathComponent(bridgeName).path) {
                    return bridge.path
                }
                return nil
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// Points IDB at the bridge directory once per process. Leaves IDB's own lookup in place when
    /// nothing is found.
    static func configure(logger: AxeLogger) throws {
        guard BundledResources.hostDirectoryPath == nil else { return }
        let directory = try resolveDirectory(
            environment: ProcessInfo.processInfo.environment,
            executablePath: Bundle.main.executablePath,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        if let directory {
            logger.info().log("IDB bridge resources: \(directory)")
            BundledResources.hostDirectoryPath = directory
        } else {
            logger.info().log("IDB bridge resources not found; using IDB's default lookup")
        }
    }
}
