import Foundation
import FBControlCore
import FBSimulatorAX
import FBSimulatorControl

struct AccessibilityRecoveryDependencies {
    typealias ProcessRunner = @MainActor (
        _ executableURL: URL,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) async throws -> Int32
    typealias Waiter = @MainActor (_ duration: Duration) async throws -> Void

    let runProcess: ProcessRunner
    let wait: Waiter
    /// Prints a warning line; stderr in live use.
    let warn: @MainActor (String) -> Void
    /// Simulators whose bridge was already restarted; shared by the whole process in live use.
    let memory: AccessibilityRecoveryMemory

    init(
        runProcess: @escaping ProcessRunner,
        wait: @escaping Waiter,
        warn: @escaping @MainActor (String) -> Void = { _ in },
        memory: AccessibilityRecoveryMemory = AccessibilityRecoveryMemory()
    ) {
        self.runProcess = runProcess
        self.wait = wait
        self.warn = warn
        self.memory = memory
    }

    static let live = AccessibilityRecoveryDependencies(
        runProcess: AccessibilityFetcher.runProcess,
        wait: { duration in try await Task.sleep(for: duration) },
        warn: { message in print(message, to: &standardError) },
        memory: .shared
    )
}

/// The simulators whose accessibility bridge a process has already restarted. A process restarts
/// each simulator's bridge at most once, so a batch or a polling loop against a service that stays
/// broken does not restart it on every read.
final class AccessibilityRecoveryMemory: @unchecked Sendable {
    static let shared = AccessibilityRecoveryMemory()

    private let lock = NSLock()
    private var recovered: Set<String> = []

    /// Records a recovery of `simulatorUDID`; false when one was already recorded.
    func beginRecovery(of simulatorUDID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recovered.insert(simulatorUDID).inserted
    }
}

/// `AXE_AX_RECOVERY`: `never` turns off the accessibility bridge restart; anything else keeps it.
enum AccessibilityRecoveryPolicy {
    static let environmentKey = "AXE_AX_RECOVERY"

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "never"
    }
}

/// A frontmost tree that is only an empty application element (see
/// `AccessibilityFetcher.isUnresponsiveTree`). Carries the tree so it can still be returned when
/// recovery is off or does not help.
struct UnresponsiveAccessibilityTree: Error, LocalizedError {
    let data: Data

    var errorDescription: String? {
        "the frontmost application has no accessibility elements"
    }
}

struct AccessibilityPoint: Equatable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

// MARK: - Accessibility Fetcher
@MainActor
struct AccessibilityFetcher {
    static func fetchAccessibilityInfoJSONData(
        for simulatorUDID: String,
        point: AccessibilityPoint? = nil,
        logger: AxeLogger,
        recoveryDependencies: AccessibilityRecoveryDependencies = .live
    ) async throws -> Data {
        let target = try await simulator(udid: simulatorUDID, logger: logger)
        return try await fetchAccessibilityInfoJSONData(
            from: target,
            simulatorUDID: simulatorUDID,
            point: point,
            logger: logger,
            recoveryDependencies: recoveryDependencies
        )
    }

    /// describe-ui's JSON.
    ///
    /// On the non-main active display of a foldable (the inner display), the frontmost tree is
    /// reduced to that display's windows with interface-point frames, and `point` (an interface
    /// point) is hit-tested against that tree in AXe, because the simulator's hit test only knows
    /// the main display (see `DescribeUIOutput`). Elsewhere, or with `allDisplays`, the
    /// simulator's output is returned unchanged.
    ///
    /// With `focusedOnly`, only the focused element of that tree is returned, without its children
    /// (`DescribeUIOutput.focusedElementData`).
    static func fetchDescribeUIJSONData(
        for simulatorUDID: String,
        point: AccessibilityPoint?,
        allDisplays: Bool,
        focusedOnly: Bool = false,
        logger: AxeLogger,
        recoveryDependencies: AccessibilityRecoveryDependencies = .live
    ) async throws -> Data {
        if focusedOnly {
            let tree = try await fetchDescribeUIJSONData(
                for: simulatorUDID,
                point: nil,
                allDisplays: allDisplays,
                logger: logger,
                recoveryDependencies: recoveryDependencies
            )
            return try DescribeUIOutput.focusedElementData(in: tree)
        }
        let simulator = try await simulator(udid: simulatorUDID, logger: logger)
        if !allDisplays {
            SimulatorDisplays.warnIfProbeDisabled(simulatorUDID: simulatorUDID, logger: logger)
        }
        let displayTarget = await DescribeUIOutput.displayTarget(allDisplays: allDisplays) {
            try await SimulatorDisplays.state(for: simulator, logger: logger)
        }
        guard let displayTarget else {
            return try await fetchAccessibilityInfoJSONData(
                from: simulator,
                simulatorUDID: simulatorUDID,
                point: point,
                logger: logger,
                recoveryDependencies: recoveryDependencies
            )
        }
        let tree = try await fetchAccessibilityInfoJSONData(
            from: simulator,
            simulatorUDID: simulatorUDID,
            point: nil,
            logger: logger,
            recoveryDependencies: recoveryDependencies
        )
        if let point {
            logger.info().log("describe-ui: hit-testing (\(point.x), \(point.y)) in the interface-point tree of display \(displayTarget.displayID); --all-displays uses the simulator's hit test")
            return try DescribeUIOutput.elementData(at: point, in: tree, target: displayTarget)
        }
        logger.info().log("describe-ui: reporting the windows of display \(displayTarget.displayID) in interface points; --all-displays prints the unfiltered tree")
        return try DescribeUIOutput.panelTreeData(tree, target: displayTarget)
    }

    private static func simulator(udid simulatorUDID: String, logger: AxeLogger) async throws -> Simulator {
        let target = try SimulatorSession.requireSimulator(udid: simulatorUDID, logger: logger)
        // Lets the coordinate mapper's display probe reuse this lookup.
        SimulatorDisplays.recordDeviceType(for: target)
        return target
    }

    /// IDB's accessibility backend (CoreSimulator's translator through the guest bridge), routed to
    /// the active display.
    private static func automation(for target: Simulator) throws -> any UIAutomation {
        try target.uiAutomation(backend: .accessibility, display: .active)
    }

    private static var requestOptions: AccessibilityRequestOptions {
        AccessibilityRequestOptions(format: .nested, keys: accessibilityOutputKeys)
    }

    private static func fetchAccessibilityInfoJSONData(
        from target: Simulator,
        simulatorUDID: String,
        point: AccessibilityPoint?,
        logger: AxeLogger,
        recoveryDependencies: AccessibilityRecoveryDependencies
    ) async throws -> Data {
        try await fetchingWithRecovery(
            simulatorUDID: simulatorUDID,
            platform: target.platform,
            logger: logger,
            dependencies: recoveryDependencies
        ) {
            if let point {
                return try await fetchAccessibilityInfoJSONData(from: target, at: point)
            }
            return try await fetchFrontmostAccessibilityInfoJSONData(from: target)
        }
    }

    /// `retryingAfterAccessibilityRecovery` for a read that returns JSON: an empty frontmost tree
    /// that recovery is off for, already used, or did not fix is returned as the simulator
    /// reported it.
    static func fetchingWithRecovery(
        simulatorUDID: String,
        platform: SimulatorPlatform = .iOS,
        logger: AxeLogger,
        dependencies: AccessibilityRecoveryDependencies,
        isEnabled: Bool = AccessibilityRecoveryPolicy.isEnabled(),
        fetch: @MainActor () async throws -> Data
    ) async throws -> Data {
        do {
            return try await retryingAfterAccessibilityRecovery(
                simulatorUDID: simulatorUDID,
                platform: platform,
                logger: logger,
                dependencies: dependencies,
                isEnabled: isEnabled,
                operation: fetch
            )
        } catch let unresponsive as UnresponsiveAccessibilityTree {
            return unresponsive.data
        }
    }

    private static func fetchAccessibilityInfoJSONData(
        from target: Simulator,
        at point: AccessibilityPoint
    ) async throws -> Data {
        let automation = try automation(for: target)
        return try await retryingTransientPointFallback(at: point) {
            let response = try await automation.describe(.point(point.cgPoint), options: requestOptions)
            return try serializedAccessibilityData(from: response)
        }
    }

    static func retryingTransientPointFallback(
        at point: AccessibilityPoint,
        maximumAttempts: Int = 5,
        fetch: @MainActor () async throws -> Data,
        wait: @MainActor (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) async throws -> Data {
        precondition(maximumAttempts > 0)
        var latestData: Data?
        for attempt in 0..<maximumAttempts {
            let data = try await fetch()
            latestData = data
            if try !isTransientPointFallback(in: data, at: point) {
                return data
            }
            if attempt < maximumAttempts - 1 {
                try await wait(.milliseconds(50 * (1 << attempt)))
            }
        }
        guard let latestData else {
            throw CLIError(errorDescription: "Accessibility element at the requested point could not be serialized.")
        }
        return latestData
    }

    private static func fetchFrontmostAccessibilityInfoJSONData(from target: Simulator) async throws -> Data {
        let automation = try automation(for: target)
        var latestData: Data?
        for attempt in 0..<5 {
            // The frontmost application's tree, as IDB's former nested serializer returned it.
            let response = try await automation.describe(.frontmost, options: requestOptions)
            let data = try serializedAccessibilityData(from: response)
            latestData = data
            if try containsAccessibilityDescendant(in: data) {
                return data
            }
            if attempt < 4 {
                try await Task.sleep(for: .milliseconds(50 * (1 << attempt)))
            }
        }
        guard let latestData else {
            throw CLIError(errorDescription: "Accessibility hierarchy could not be serialized.")
        }
        if isUnresponsiveTree(latestData) {
            throw UnresponsiveAccessibilityTree(data: latestData)
        }
        return latestData
    }

    /// Runs `operation` and, when the simulator's accessibility service stops answering, restarts
    /// the simulator's `com.apple.CoreSimulator.bridge` once (in the launchd domain for `platform`,
    /// see `accessibilityBridgeDomains(for:)`) and runs `operation` again.
    ///
    /// After some boots, and after an app is terminated and relaunched, the service names no
    /// frontmost application or returns an empty application element for minutes; restarting the
    /// bridge fixes it at once. The restart is announced on stderr. `AXE_AX_RECOVERY=never` turns
    /// it off. A second failure is thrown as it is.
    ///
    /// The bridge of a simulator is restarted at most once per process (`dependencies.memory`);
    /// later failures are thrown as they are. When the restart itself fails, a warning says so and
    /// the original failure is thrown, so an empty tree is still returned by the caller.
    static func retryingAfterAccessibilityRecovery<T>(
        simulatorUDID: String,
        platform: SimulatorPlatform = .iOS,
        logger: AxeLogger,
        dependencies: AccessibilityRecoveryDependencies,
        isEnabled: Bool = AccessibilityRecoveryPolicy.isEnabled(),
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isEnabled, needsAccessibilityRecovery(after: error) else {
                throw error
            }
            guard dependencies.memory.beginRecovery(of: simulatorUDID) else {
                logger.info().log("Accessibility service unresponsive; the bridge was already restarted in this process, so not restarting it again")
                throw error
            }
            dependencies.warn(
                "Warning: the simulator's accessibility service is not answering (\(error.localizedDescription)); restarting com.apple.CoreSimulator.bridge and retrying once. Set \(AccessibilityRecoveryPolicy.environmentKey)=never to disable this."
            )
            logger.info().log("Accessibility service unresponsive; restarting com.apple.CoreSimulator.bridge and retrying once")
            do {
                try await restartAccessibilityBridge(simulatorUDID: simulatorUDID, platform: platform, dependencies: dependencies)
            } catch is CancellationError {
                throw CancellationError()
            } catch let restartError {
                dependencies.warn("Warning: restarting com.apple.CoreSimulator.bridge failed: \(restartError.localizedDescription)")
                throw error
            }
            return try await operation()
        }
    }

    /// True for the failures a bridge restart fixes: no frontmost application, a service that does
    /// not answer, or an empty frontmost tree. Other errors, such as nothing at a point, are not.
    /// (A marker query without a match also has no translation object; AXe sends none, and such a
    /// miss is not a broken service, so it is not listed.)
    static func needsAccessibilityRecovery(after error: Error) -> Bool {
        if error is UnresponsiveAccessibilityTree {
            return true
        }
        guard let error = error as? AccessibilityError else { return false }
        switch error {
        case .noTranslationObject(.frontmost), .serviceNotAnswering:
            return true
        default:
            return false
        }
    }

    static let accessibilityBridgeLabel = "com.apple.CoreSimulator.bridge"

    /// The launchd domains that hold the accessibility bridge, in the order AXe tries them.
    ///
    /// Inspected with `simctl spawn <udid> launchctl print <domain>` on Xcode 27.2 runtimes: iOS
    /// and visionOS run the bridge in `user/foreground`; watchOS has no `user/foreground` domain
    /// ("Unrecognized target specifier") and runs it in `system`. tvOS is unverified (no runtime
    /// was available), so both domains are tried.
    static func accessibilityBridgeDomains(for platform: SimulatorPlatform) -> [String] {
        switch platform {
        case .iOS, .visionOS:
            return ["user/foreground"]
        case .watchOS:
            return ["system"]
        case .tvOS, .unknown:
            return ["user/foreground", "system"]
        }
    }

    static func restartAccessibilityBridge(
        simulatorUDID: String,
        platform: SimulatorPlatform = .iOS,
        dependencies: AccessibilityRecoveryDependencies
    ) async throws {
        // One entry per domain tried: "<domain>: exited with N" or "<domain>: <error>". A domain
        // that fails or times out does not stop the next one from being tried.
        var failures: [String] = []
        for domain in accessibilityBridgeDomains(for: platform) {
            let arguments = [
                "simctl",
                "spawn",
                simulatorUDID,
                "launchctl",
                "kickstart",
                "-k",
                "\(domain)/\(accessibilityBridgeLabel)",
            ]
            let status: Int32
            do {
                status = try await dependencies.runProcess(
                    URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments,
                    // `simctl spawn` can take several seconds on a simulator that has just booted.
                    15
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(domain): \(error.localizedDescription)")
                continue
            }
            if status == 0 {
                try await dependencies.wait(.seconds(1))
                return
            }
            failures.append("\(domain): launchctl exited with \(status)")
        }
        throw CLIError(
            errorDescription: "AXe could not restart the accessibility service of simulator \(simulatorUDID) (\(failures.joined(separator: "; "))). Restart the simulator and try again."
        )
    }

    /// True when every root of a frontmost tree is an empty application element: no children and
    /// an all-zero frame. The accessibility service returns this while it is wedged.
    static func isUnresponsiveTree(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        let roots: [[String: Any]]
        if let array = object as? [[String: Any]] {
            roots = array
        } else if let root = object as? [String: Any] {
            roots = [root]
        } else {
            return false
        }
        return !roots.isEmpty && roots.allSatisfy { root in
            let children = root["children"] as? [Any] ?? []
            guard children.isEmpty, let frame = root["frame"] as? [String: Any] else { return false }
            return ["x", "y", "width", "height"].allSatisfy { key in
                (frame[key] as? NSNumber)?.doubleValue == 0
            }
        }
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                terminateProcess(process)
                throw error
            }
        }
        if process.isRunning {
            terminateProcess(process)
            throw CLIError(errorDescription: "AXe timed out restarting the simulator's accessibility service. Wait for the simulator to finish booting and try again.")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func terminateProcess(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }

    /// The legacy Foundation rendering keeps AXe's JSON keys and number formatting unchanged.
    private static func serializedAccessibilityData(from response: AccessibilityElementsResponse) throws -> Data {
        try serializeAccessibilityInfo(addingCompatibilityDefaults(to: response.elements.legacyFoundationObject))
    }

    static func containsAccessibilityDescendant(in data: Data) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data)
        let roots: [[String: Any]]
        if let array = object as? [[String: Any]] {
            roots = array
        } else if let root = object as? [String: Any] {
            roots = [root]
        } else {
            return false
        }
        return roots.contains { root in
            guard let children = root["children"] as? [Any] else { return false }
            return !children.isEmpty
        }
    }

    static func isTransientPointFallback(in data: Data, at point: AccessibilityPoint) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data)
        let root: [String: Any]?
        if let dictionary = object as? [String: Any] {
            root = dictionary
        } else if let dictionaries = object as? [[String: Any]], dictionaries.count == 1 {
            root = dictionaries.first
        } else {
            root = nil
        }
        let meaningfulKeys = [
            "AXLabel",
            "AXUniqueId",
            "AXIdentifier",
            "AXValue",
            "title",
            "help",
            "custom_actions",
            "children",
        ]
        guard let root,
              !meaningfulKeys.contains(where: { hasMeaningfulValue(root[$0]) }) else {
            return false
        }

        let decoder = JSONDecoder()
        let element: AccessibilityElement
        if let decoded = try? decoder.decode(AccessibilityElement.self, from: data) {
            element = decoded
        } else if let decoded = try? decoder.decode([AccessibilityElement].self, from: data),
                  let first = decoded.first,
                  decoded.count == 1 {
            element = first
        } else {
            return false
        }

        guard element.type == "Group",
              element.role == "AXGroup",
              element.normalizedLabel == nil,
              element.normalizedUniqueId == nil,
              element.normalizedValue == nil,
              element.children?.isEmpty != false,
              let frame = element.frame,
              abs(frame.x) < 1,
              abs(frame.y) < 1 else {
            return false
        }
        let containsPoint = point.x >= frame.x
            && point.x <= frame.x + frame.width
            && point.y >= frame.y
            && point.y <= frame.y + frame.height
        return containsPoint
            && min(frame.width, frame.height) >= 300
            && max(frame.width, frame.height) >= 600
    }

    private static func hasMeaningfulValue(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull:
            return false
        case let string as String:
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let array as [Any]:
            return !array.isEmpty
        case let dictionary as [String: Any]:
            return !dictionary.isEmpty
        default:
            return true
        }
    }

    static func fetchAccessibilityElements(for simulatorUDID: String, logger: AxeLogger) async throws -> [AccessibilityElement] {
        let jsonData = try await fetchAccessibilityInfoJSONData(for: simulatorUDID, point: nil, logger: logger)
        let decoder = JSONDecoder()
        
        if let roots = try? decoder.decode([AccessibilityElement].self, from: jsonData) {
            return roots
        }
        
        let root = try decoder.decode(AccessibilityElement.self, from: jsonData)
        return [root]
    }

    static func serializeAccessibilityInfo(_ accessibilityInfo: Any) throws -> Data {
        guard accessibilityInfo is [String: Any] || accessibilityInfo is [[String: Any]] else {
            throw CLIError(errorDescription: "AXe received an unsupported accessibility response from the simulator.")
        }
        return try JSONSerialization.data(withJSONObject: accessibilityInfo, options: [.prettyPrinted])
    }

    /// Adds an empty `traits` array to every element that has none, so the key is always present.
    static func addingCompatibilityDefaults(to accessibilityInfo: Any) -> Any {
        if let elements = accessibilityInfo as? [Any] {
            return elements.map(addingCompatibilityDefaults)
        }
        guard var element = accessibilityInfo as? [String: Any] else {
            return accessibilityInfo
        }
        for (key, value) in element {
            element[key] = addingCompatibilityDefaults(to: value)
        }
        if element["type"] != nil, element["traits"] == nil {
            element["traits"] = [String]()
        }
        return element
    }

    // This key set preserves AXe's legacy public JSON schema; update it only with explicit schema coverage.
    // IDB's accessibility backend returns `traits` (the fork's serializer emptied the hierarchy when
    // they were requested, so AXe used to print an empty placeholder). `focused` is true on the element
    // that has focus (the tvOS focus engine's focused item) and false or null elsewhere.
    static let accessibilityOutputKeys: Set<AXKeys> = [
        .label,
        .frame,
        .value,
        .uniqueID,
        .type,
        .title,
        .frameDict,
        .help,
        .enabled,
        .customActions,
        .role,
        .roleDescription,
        .subrole,
        .contentRequired,
        .pid,
        .traits,
        .focused,
    ]
}
