import Foundation

// MARK: - Request

/// The element `axe focus` moves tvOS focus to.
enum FocusQuery: Equatable, Sendable {
    case label(String)
    case id(String)

    /// The option as the user typed it, for messages: `--label 'General'`.
    var optionDescription: String {
        "\(kind) '\(rawValue)'"
    }

    var kind: String {
        switch self {
        case .label: return "--label"
        case .id: return "--id"
        }
    }

    var rawValue: String {
        switch self {
        case .label(let value), .id(let value): return value
        }
    }

    /// True when `element` carries the label or identifier: trimmed and exact, except that every
    /// whitespace character counts as a plain space (tvOS Settings labels its "Screen Saver" row
    /// with a no-break space).
    func matches(_ element: AccessibilityElement) -> Bool {
        let value = Self.normalized(rawValue)
        switch self {
        case .label:
            return element.normalizedLabel.map(Self.normalized) == value
        case .id:
            return element.normalizedUniqueId.map(Self.normalized) == value
        }
    }

    static func normalized(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).map { $0.isWhitespace ? " " : $0 })
    }
}

struct FocusRequest: Equatable, Sendable {
    static let defaultMaxSteps = 50
    static let maximumMaxSteps = 500
    /// Reads of the tree after a press before AXe concludes the press did not move focus.
    static let defaultChangeChecks = 10
    static let defaultCheckInterval: Duration = .milliseconds(100)

    let query: FocusQuery
    let maxSteps: Int
    let select: Bool
    /// How long the first read may be repeated until the target and a focused element are in the
    /// tree (after a screen transition); zero reads once, like `tap --wait-timeout 0`.
    let waitTimeout: Duration
    let pollInterval: Duration
    let changeChecks: Int
    let checkInterval: Duration

    init(
        query: FocusQuery,
        maxSteps: Int = defaultMaxSteps,
        select: Bool = false,
        waitTimeout: Duration = .zero,
        pollInterval: Duration = .milliseconds(250),
        changeChecks: Int = defaultChangeChecks,
        checkInterval: Duration = defaultCheckInterval
    ) {
        self.query = query
        self.maxSteps = maxSteps
        self.select = select
        self.waitTimeout = waitTimeout
        self.pollInterval = pollInterval
        self.changeChecks = changeChecks
        self.checkInterval = checkInterval
    }

    /// A copy whose wait for the target uses `seconds` and `pollSeconds`.
    func waiting(seconds: Double, pollSeconds: Double) -> FocusRequest {
        FocusRequest(
            query: query,
            maxSteps: maxSteps,
            select: select,
            waitTimeout: .milliseconds(Int64((seconds * 1000).rounded())),
            pollInterval: .milliseconds(Int64((pollSeconds * 1000).rounded())),
            changeChecks: changeChecks,
            checkInterval: checkInterval
        )
    }
}

// MARK: - Focus State

/// The focused element as far as navigation cares: what it is called and where it is. Two reads
/// with the same item mean focus did not move.
struct FocusedItem: Hashable, Sendable {
    let label: String?
    let identifier: String?
    let frame: AccessibilityElement.Frame

    init(label: String?, identifier: String?, frame: AccessibilityElement.Frame) {
        self.label = label
        self.identifier = identifier
        self.frame = frame
    }

    init?(_ element: AccessibilityElement) {
        guard let frame = element.frame else { return nil }
        self.init(label: element.normalizedLabel, identifier: element.normalizedUniqueId, frame: frame)
    }

    /// `'General'`, `--id 'AppCell'`, or the frame when the element names nothing.
    var description: String {
        if let label { return "'\(label)'" }
        if let identifier { return "the element with id '\(identifier)'" }
        return "the element at (\(Int(frame.x)), \(Int(frame.y)), \(Int(frame.width))x\(Int(frame.height)))"
    }
}

// MARK: - Planner

/// Decides the next Siri Remote press from where focus is and where the target is. Pure: it
/// remembers which directions it already pressed from each focus state, so it never repeats a
/// press that is known not to help and always ends.
struct FocusPlanner: Equatable {
    enum Decision: Equatable {
        /// Focus is on the target, or on an element that contains the target's centre (a focused
        /// cell whose label is a child text element).
        case arrived
        case press(RemoteAction)
        /// Every direction toward the target was already pressed from this focus state.
        case stuck(tried: [RemoteAction])
    }

    private(set) var tried: [FocusedItem: [RemoteAction]] = [:]

    /// The d-pad directions that bring focus closer to `target`, in the order to try them: the
    /// vertical one when the target's centre is above or below the focused frame, then the
    /// horizontal one when it is beside it. Vertical first follows tvOS layouts, where rows of
    /// items (shelves, lists, tab bars) are reached by moving between rows and then along one.
    /// Frames are half-open, like `Frame.contains`.
    static func directions(from focused: AccessibilityElement.Frame, toward target: AccessibilityElement.Frame) -> [RemoteAction] {
        var directions: [RemoteAction] = []
        if target.midY < focused.y {
            directions.append(.up)
        } else if target.midY >= focused.y + focused.height {
            directions.append(.down)
        }
        if target.midX < focused.x {
            directions.append(.left)
        } else if target.midX >= focused.x + focused.width {
            directions.append(.right)
        }
        return directions
    }

    mutating func next(
        focused: FocusedItem,
        target: AccessibilityElement.Frame,
        focusedIsTarget: Bool = false
    ) -> Decision {
        if focusedIsTarget || focused.frame.contains(x: target.midX, y: target.midY) {
            return .arrived
        }
        let used = tried[focused, default: []]
        let candidates = Self.directions(from: focused.frame, toward: target)
        guard let direction = candidates.first(where: { !used.contains($0) }) else {
            return candidates.isEmpty ? .arrived : .stuck(tried: used)
        }
        tried[focused, default: []].append(direction)
        return .press(direction)
    }
}

// MARK: - Errors

enum FocusNavigationError: LocalizedError, Equatable {
    case targetNotFound(query: FocusQuery)
    case noFocusedElement
    case focusedElementWithoutFrame
    case stuck(focused: String, tried: [RemoteAction], query: FocusQuery, presses: Int)
    case outOfSteps(focused: String, query: FocusQuery, maxSteps: Int)

    var errorDescription: String? {
        switch self {
        case .targetNotFound(let query):
            return "No accessibility element matched \(query.optionDescription) on this screen, so AXe cannot tell which way to move focus. tvOS lists and shelves keep only the items near focus in the accessibility tree: move focus toward the target with `axe remote` (or `axe focus` to an item that is in the tree) and try again. Run `axe describe-ui --udid <SIMULATOR_UDID>` to see the elements."
        case .noFocusedElement:
            return "\(DescribeUIOutput.noFocusedElementMessage) Focus can only be moved from a focused element; press `axe remote` once to give the screen focus."
        case .focusedElementWithoutFrame:
            return "The focused element reports no frame, so AXe cannot tell which way the target is. Use `axe remote` and `axe describe-ui --focused`."
        case .stuck(let focused, let tried, let query, let presses):
            let directions = tried.map(\.rawValue).joined(separator: " and ")
            return "Focus is stuck on \(focused): pressing \(directions) did not move it toward \(query.optionDescription) (\(presses) press(es) sent). The target may not be focusable, or may be reachable only by another route; use `axe remote` and `axe describe-ui --focused`."
        case .outOfSteps(let focused, let query, let maxSteps):
            return "Focus did not reach \(query.optionDescription) within --max-steps \(maxSteps) presses; it is on \(focused). Raise --max-steps, or check the screen with `axe describe-ui --focused`."
        }
    }
}

// MARK: - Navigation

struct FocusResult: Equatable {
    let focused: FocusedItem
    /// The d-pad presses sent, in order (select excluded).
    let presses: [RemoteAction]
    let selected: Bool

    var summary: String {
        let moves = presses.isEmpty ? "already focused" : "\(presses.count) remote press(es): \(presses.map(\.rawValue).joined(separator: " "))"
        let selection = selected ? ", then select" : ""
        return "Focused \(focused.description) (\(moves)\(selection))"
    }
}

@MainActor
enum FocusNavigator {
    /// The focused element of a tree: the deepest element whose `focused` is true, as
    /// `describe-ui --focused` prints it.
    static func focusedItem(in roots: [AccessibilityElement]) throws -> (item: FocusedItem, element: AccessibilityElement) {
        guard let element = DescribeUIOutput.focusedElement(in: roots) else {
            throw FocusNavigationError.noFocusedElement
        }
        guard let item = FocusedItem(element) else {
            throw FocusNavigationError.focusedElementWithoutFrame
        }
        return (item, element)
    }

    /// The frame focus has to reach for `query`. Application roots never count (an app's root
    /// carries the app name as its label). Elements a remote can focus (buttons, cells: see
    /// `AccessibilityElement.isActionable`) win over others; matches with the same frame (tvOS
    /// lists report a row and its text, or two copies of a row, at one frame) are one target.
    /// When distinct frames remain, the one that contains the centres of all others wins (a row
    /// and the text inside it); otherwise the query is ambiguous.
    nonisolated static func targetFrame(for query: FocusQuery, in roots: [AccessibilityElement]) throws -> AccessibilityElement.Frame {
        let matches = roots.flatMap { $0.flattened() }
            .filter { $0.type != "Application" && query.matches($0) }
        let focusable = matches.filter(\.isActionable)
        let preferred = focusable.isEmpty ? matches : focusable
        var frames: [AccessibilityElement.Frame] = []
        for frame in preferred.compactMap(\.frame) where frame.width > 0 && frame.height > 0 && !frames.contains(frame) {
            frames.append(frame)
        }
        guard !frames.isEmpty else {
            throw FocusNavigationError.targetNotFound(query: query)
        }
        if frames.count == 1 {
            return frames[0]
        }
        if let container = frames.first(where: { outer in
            frames.allSatisfy { $0 == outer || outer.contains(x: $0.midX, y: $0.midY) }
        }) {
            return container
        }
        let hasUniqueIDs = preferred.contains { $0.normalizedUniqueId != nil }
        throw ElementResolutionError.multipleMatches(count: frames.count, kind: query.kind, value: query.rawValue, hasUniqueIDs: hasUniqueIDs)
    }

    /// Moves focus to `request.query`: reads the tree, presses the d-pad direction the planner
    /// picks, waits for focus to change (up to `changeChecks` reads `checkInterval` apart), and
    /// repeats until the target is focused, then presses select with `request.select`.
    ///
    /// - Throws: not found or ambiguous target (`ElementResolutionError`), no focused element,
    ///   focus stuck, or `maxSteps` presses used up (`FocusNavigationError`).
    static func navigate(
        _ request: FocusRequest,
        readTree: () async throws -> [AccessibilityElement],
        press: (RemoteAction) async throws -> Void,
        sleep: (Duration) async throws -> Void,
        elapsed: () -> Duration = { .zero },
        log: (String) -> Void = { _ in }
    ) async throws -> FocusResult {
        var planner = FocusPlanner()
        var presses: [RemoteAction] = []
        var roots = try await readTree()
        // With a wait timeout, read again until the target and a focused element are there.
        while !isReady(roots, for: request.query), elapsed() < request.waitTimeout {
            log("Target or focused element not in the tree yet; reading again in \(request.pollInterval)")
            try await sleep(request.pollInterval)
            roots = try await readTree()
        }

        while true {
            let (focused, focusedElement) = try focusedItem(in: roots)
            let decision: FocusPlanner.Decision
            if request.query.matches(focusedElement) {
                decision = .arrived
            } else {
                decision = planner.next(focused: focused, target: try targetFrame(for: request.query, in: roots))
            }

            switch decision {
            case .arrived:
                if request.select {
                    try await press(.select)
                }
                return FocusResult(focused: focused, presses: presses, selected: request.select)
            case .stuck(let tried):
                throw FocusNavigationError.stuck(focused: focused.description, tried: tried, query: request.query, presses: presses.count)
            case .press(let direction):
                guard presses.count < request.maxSteps else {
                    throw FocusNavigationError.outOfSteps(focused: focused.description, query: request.query, maxSteps: request.maxSteps)
                }
                log("Focus on \(focused.description); pressing \(direction.rawValue)")
                try await press(direction)
                presses.append(direction)
                roots = try await readTree()
                // The focus engine can report the old item, or none, for a moment after a press.
                var checks = 1
                while checks < request.changeChecks {
                    if let item = try? focusedItem(in: roots).item, item != focused {
                        break
                    }
                    try await sleep(request.checkInterval)
                    roots = try await readTree()
                    checks += 1
                }
            }
        }
    }

    /// False while the tree has no focused element, or neither the focused element nor any other
    /// element matches `query` (a screen still in transition). An ambiguous target is ready: more
    /// reads would not resolve it.
    nonisolated static func isReady(_ roots: [AccessibilityElement], for query: FocusQuery) -> Bool {
        guard let focused = DescribeUIOutput.focusedElement(in: roots) else { return false }
        if query.matches(focused) { return true }
        do {
            _ = try targetFrame(for: query, in: roots)
            return true
        } catch FocusNavigationError.targetNotFound {
            return false
        } catch {
            return true
        }
    }

    /// `navigate` against a simulator: reads its accessibility tree and sends presses with `press`.
    static func navigate(
        _ request: FocusRequest,
        simulatorUDID: String,
        logger: AxeLogger,
        press: (RemoteAction) async throws -> Void
    ) async throws -> FocusResult {
        let start = ContinuousClock.now
        return try await navigate(
            request,
            readTree: { try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger) },
            press: press,
            sleep: { try await Task.sleep(for: $0) },
            elapsed: { ContinuousClock.now - start },
            log: { logger.info().log($0) }
        )
    }
}
