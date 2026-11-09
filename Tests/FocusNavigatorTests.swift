import ArgumentParser
import Foundation
import Testing
@testable import AXe

private typealias Frame = AccessibilityElement.Frame

private func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Frame {
    Frame(x: x, y: y, width: width, height: height)
}

private func item(_ label: String, _ frame: Frame) -> FocusedItem {
    FocusedItem(label: label, identifier: nil, frame: frame)
}

private func decode(_ json: String) throws -> [AccessibilityElement] {
    try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
}

@Suite("Focus planner")
struct FocusPlannerTests {
    private let focused = frame(100, 100, 200, 50)

    @Test(
        "The direction comes from the target centre against the focused frame, vertical first",
        arguments: [
            (frame(100, 300, 200, 50), [RemoteAction.down]),
            (frame(100, 0, 200, 50), [.up]),
            (frame(400, 100, 200, 50), [.right]),
            (frame(0, 110, 50, 30), [.left]),
            (frame(400, 300, 200, 50), [.down, .right]),
            (frame(0, 0, 50, 50), [.up, .left]),
            (frame(150, 110, 20, 20), []),
        ]
    )
    func directions(target: AccessibilityElement.Frame, expected: [RemoteAction]) {
        #expect(FocusPlanner.directions(from: focused, toward: target) == expected)
    }

    @Test("Frames are half-open: a target centred on the focused frame's bottom edge is below it")
    func halfOpen() {
        // Centre y = 150 = focused.maxY.
        #expect(FocusPlanner.directions(from: focused, toward: frame(100, 140, 200, 20)) == [.down])
    }

    @Test("Focus on the target, or on an element containing its centre, has arrived")
    func arrived() {
        var planner = FocusPlanner()
        #expect(planner.next(focused: item("Row", focused), target: frame(150, 110, 20, 20)) == .arrived)
        #expect(planner.next(focused: item("Row", focused), target: frame(0, 500, 10, 10), focusedIsTarget: true) == .arrived)
        #expect(planner.tried.isEmpty)
    }

    @Test("A direction that did not move focus is not pressed again; the other axis is tried, then stuck")
    func stuck() {
        var planner = FocusPlanner()
        let state = item("General", focused)
        let target = frame(0, 0, 50, 50)
        #expect(planner.next(focused: state, target: target) == .press(.up))
        // Focus did not move: same state again.
        #expect(planner.next(focused: state, target: target) == .press(.left))
        #expect(planner.next(focused: state, target: target) == .stuck(tried: [.up, .left]))
    }

    @Test("Each focus state remembers its own presses, so returning to a state does not loop")
    func memoryPerState() {
        var planner = FocusPlanner()
        let a = item("A", focused)
        let b = item("B", frame(100, 200, 200, 50))
        let target = frame(400, 400, 50, 50)
        #expect(planner.next(focused: a, target: target) == .press(.down))
        #expect(planner.next(focused: b, target: target) == .press(.down))
        // B's down led back to A (an odd layout): A goes right instead of down again.
        #expect(planner.next(focused: a, target: target) == .press(.right))
        #expect(planner.tried[a] == [.down, .right])
    }
}

@Suite("Focus target resolution")
@MainActor
struct FocusTargetTests {
    /// A tvOS Settings-like tree: each row is a button with a text child of the same label at a
    /// smaller frame, the list is reported twice at the same frames, and the app root carries the
    /// app name.
    private static let settings = #"""
    [{"type":"Application","AXLabel":"Settings","frame":{"x":0,"y":0,"width":1920,"height":1080},"children":[
      {"type":"StaticText","AXLabel":"Settings","frame":{"x":200,"y":60,"width":200,"height":50}},
      {"type":"Button","AXLabel":"General","focused":true,"frame":{"x":1056,"y":188,"width":788,"height":66},"children":[
        {"type":"StaticText","AXLabel":"General","frame":{"x":1086,"y":198,"width":132,"height":46}}]},
      {"type":"Button","AXLabel":"Developer","frame":{"x":1060,"y":989,"width":780,"height":66},"children":[
        {"type":"StaticText","AXLabel":"Developer","frame":{"x":1090,"y":999,"width":171,"height":46}}]},
      {"type":"Button","AXLabel":"Developer","frame":{"x":1060,"y":989,"width":780,"height":66}},
      {"type":"Group","AXLabel":"Screen Saver","AXUniqueId":"saver","frame":{"x":1060,"y":509,"width":780,"height":66}},
      {"type":"Button","AXLabel":"Twice","frame":{"x":0,"y":0,"width":10,"height":10}},
      {"type":"Button","AXLabel":"Twice","frame":{"x":500,"y":500,"width":10,"height":10}}
    ]}]
    """#

    private let roots: [AccessibilityElement]

    init() throws {
        roots = try decode(Self.settings)
    }

    @Test("A focusable match wins over its text; copies at the same frame are one target")
    func prefersButtons() throws {
        #expect(try FocusNavigator.targetFrame(for: .label("Developer"), in: roots) == frame(1060, 989, 780, 66))
        #expect(try FocusNavigator.targetFrame(for: .label("General"), in: roots) == frame(1056, 188, 788, 66))
    }

    @Test("The application root never matches; a non-focusable match is used when it is the only one")
    func applicationRoot() throws {
        #expect(try FocusNavigator.targetFrame(for: .label("Settings"), in: roots) == frame(200, 60, 200, 50))
    }

    @Test("Whitespace variants match a plain space, and --id matches the identifier")
    func whitespaceAndID() throws {
        #expect(try FocusNavigator.targetFrame(for: .label("Screen Saver"), in: roots) == frame(1060, 509, 780, 66))
        #expect(try FocusNavigator.targetFrame(for: .label("  Screen Saver "), in: roots) == frame(1060, 509, 780, 66))
        #expect(try FocusNavigator.targetFrame(for: .id("saver"), in: roots) == frame(1060, 509, 780, 66))
    }

    @Test("A missing target names the query and the tvOS tree limit")
    func notFound() {
        #expect(throws: FocusNavigationError.targetNotFound(query: .label("Network"))) {
            _ = try FocusNavigator.targetFrame(for: .label("Network"), in: roots)
        }
        let message = FocusNavigationError.targetNotFound(query: .label("Network")).errorDescription ?? ""
        #expect(message.contains("--label 'Network'"))
        #expect(message.contains("axe remote"))
    }

    @Test("Matches at distinct frames, none containing the others, are ambiguous")
    func ambiguous() {
        do {
            _ = try FocusNavigator.targetFrame(for: .label("Twice"), in: roots)
            Issue.record("Expected an ambiguity error")
        } catch let error as ElementResolutionError {
            guard case .multipleMatches(let count, let kind, _, _) = error else {
                Issue.record("Expected multipleMatches, got \(error)")
                return
            }
            #expect(count == 2 && kind == "--label")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("The focused element is the deepest focused one")
    func focusedItem() throws {
        let (focused, element) = try FocusNavigator.focusedItem(in: roots)
        #expect(focused == item("General", frame(1056, 188, 788, 66)))
        #expect(element.type == "Button")
        #expect(throws: FocusNavigationError.noFocusedElement) {
            _ = try FocusNavigator.focusedItem(in: decode(#"[{"type":"Application","children":[]}]"#))
        }
    }
}

/// A vertical tvOS list driven by d-pad presses: rows 70 points apart, focus on one row.
@MainActor
private final class FakeTVList {
    var labels: [String]
    var focusedIndex: Int
    /// Reads that report the old focus after a press, as the focus engine can for a moment.
    var lagReads = 0
    /// Reads, from the start, that have no focused element (a screen in transition).
    var emptyReads = 0
    var pressed: [RemoteAction] = []
    var reads = 0
    private var pendingIndex: Int?

    init(labels: [String], focusedIndex: Int = 0) {
        self.labels = labels
        self.focusedIndex = focusedIndex
    }

    func press(_ action: RemoteAction) {
        pressed.append(action)
        var index = focusedIndex
        switch action {
        case .down: index = min(index + 1, labels.count - 1)
        case .up: index = max(index - 1, 0)
        default: break
        }
        if lagReads > 0 {
            pendingIndex = index
        } else {
            focusedIndex = index
        }
    }

    func read() throws -> [AccessibilityElement] {
        reads += 1
        if reads <= emptyReads {
            return try decode(#"[{"type":"Application","frame":{"x":0,"y":0,"width":1920,"height":1080},"children":[]}]"#)
        }
        if let pendingIndex {
            if lagReads > 0 {
                lagReads -= 1
            } else {
                focusedIndex = pendingIndex
                self.pendingIndex = nil
            }
        }
        let rows = labels.enumerated().map { index, label in
            #"{"type":"Button","AXLabel":"\#(label)","focused":\#(index == focusedIndex),"frame":{"x":1000,"y":\#(100 + index * 70),"width":800,"height":66}}"#
        }
        let title = #"{"type":"StaticText","AXLabel":"Title","frame":{"x":100,"y":20,"width":200,"height":40}}"#
        return try decode(#"[{"type":"Application","frame":{"x":0,"y":0,"width":1920,"height":1080},"children":[\#(([title] + rows).joined(separator: ","))]}]"#)
    }
}

@Suite("Focus navigation")
@MainActor
struct FocusNavigationTests {
    private func navigate(_ list: FakeTVList, _ request: FocusRequest, clock: (() -> Duration)? = nil) async throws -> FocusResult {
        var sleeps: Duration = .zero
        return try await FocusNavigator.navigate(
            request,
            readTree: { try list.read() },
            press: { list.press($0) },
            sleep: { sleeps += $0 },
            elapsed: clock ?? { sleeps }
        )
    }

    private let rows = ["General", "Profiles", "Video", "Screen Saver", "Network"]

    @Test("Presses down until the target has focus")
    func reachesTarget() async throws {
        let list = FakeTVList(labels: rows)
        let result = try await navigate(list, FocusRequest(query: .label("Screen Saver")))
        #expect(result.presses == [.down, .down, .down])
        #expect(result.focused.label == "Screen Saver")
        #expect(!result.selected)
        #expect(list.pressed == [.down, .down, .down])
        #expect(result.summary == "Focused 'Screen Saver' (3 remote press(es): down down down)")
    }

    @Test("Already focused: no press; --select presses select once")
    func alreadyFocusedWithSelect() async throws {
        let list = FakeTVList(labels: rows, focusedIndex: 2)
        let result = try await navigate(list, FocusRequest(query: .label("Video"), select: true))
        #expect(result.presses.isEmpty)
        #expect(result.selected)
        #expect(list.pressed == [.select])
        #expect(result.summary == "Focused 'Video' (already focused, then select)")
    }

    @Test("A focus engine that reports the old item for a moment is waited for, not taken as stuck")
    func lag() async throws {
        let list = FakeTVList(labels: rows, focusedIndex: 4)
        list.lagReads = 2
        let result = try await navigate(list, FocusRequest(query: .label("Video")))
        #expect(result.presses == [.up, .up])
    }

    @Test("A target focus cannot reach fails as stuck after trying each direction toward it")
    func stuck() async throws {
        let list = FakeTVList(labels: rows, focusedIndex: 1)
        do {
            _ = try await navigate(list, FocusRequest(query: .label("Title"), changeChecks: 2))
            Issue.record("Expected stuck")
        } catch let error as FocusNavigationError {
            #expect(error == .stuck(focused: "'General'", tried: [.up, .left], query: .label("Title"), presses: 3))
            #expect(error.errorDescription?.hasPrefix("Focus is stuck on 'General': pressing up and left did not move it toward --label 'Title' (3 press(es) sent).") == true)
        }
        #expect(list.pressed == [.up, .up, .left])
    }

    @Test("--max-steps bounds the presses")
    func outOfSteps() async throws {
        let list = FakeTVList(labels: rows)
        do {
            _ = try await navigate(list, FocusRequest(query: .label("Network"), maxSteps: 2))
            Issue.record("Expected out of steps")
        } catch let error as FocusNavigationError {
            #expect(error == .outOfSteps(focused: "'Video'", query: .label("Network"), maxSteps: 2))
        }
        #expect(list.pressed.count == 2)
        // The last allowed press may still arrive.
        let exact = FakeTVList(labels: rows)
        #expect(try await navigate(exact, FocusRequest(query: .label("Network"), maxSteps: 4)).presses.count == 4)
    }

    @Test("A missing target fails before any press; --wait-timeout reads again until it appears")
    func waitForTarget() async throws {
        let missing = FakeTVList(labels: rows)
        await #expect(throws: FocusNavigationError.targetNotFound(query: .label("Apps"))) {
            _ = try await navigate(missing, FocusRequest(query: .label("Apps")))
        }
        #expect(missing.pressed.isEmpty)

        let transitioning = FakeTVList(labels: rows)
        transitioning.emptyReads = 2
        let request = FocusRequest(query: .label("Video")).waiting(seconds: 1, pollSeconds: 0.25)
        #expect(try await navigate(transitioning, request).presses == [.down, .down])
        #expect(transitioning.reads >= 3)

        let noWait = FakeTVList(labels: rows)
        noWait.emptyReads = 1
        await #expect(throws: FocusNavigationError.noFocusedElement) {
            _ = try await navigate(noWait, FocusRequest(query: .label("Video")))
        }
    }

    @Test("Readiness: a focused element plus a match, or an ambiguous match")
    func readiness() throws {
        let list = FakeTVList(labels: rows)
        let roots = try list.read()
        #expect(FocusNavigator.isReady(roots, for: .label("Network")))
        #expect(!FocusNavigator.isReady(roots, for: .label("Apps")))
        #expect(!FocusNavigator.isReady(try decode(#"[{"type":"Application","children":[{"type":"Button","AXLabel":"Network"}]}]"#), for: .label("Network")))
    }
}

@Suite("Focus command")
struct FocusCommandTests {
    private static let udid = "00000000-0000-0000-0000-000000000000"

    @Test("Parses --label or --id with its options")
    func parsing() throws {
        let byLabel = try Focus.parse(["--label", "General", "--udid", Self.udid])
        #expect(byLabel.request == FocusRequest(query: .label("General")))
        let byID = try Focus.parse(["--id", "AppCell", "--max-steps", "5", "--select", "--wait-timeout", "2", "--udid", Self.udid])
        #expect(byID.request.query == .id("AppCell"))
        #expect(byID.request.maxSteps == 5)
        #expect(byID.request.select)
        #expect(byID.request.waitTimeout == .seconds(2))
        #expect(byID.request.pollInterval == .milliseconds(250))
    }

    @Test(
        "Invalid selectors and options are refused",
        arguments: [
            [String](),
            ["--label", "A", "--id", "B"],
            ["--label", "  "],
            ["--label", "A", "--max-steps", "0"],
            ["--label", "A", "--max-steps", "501"],
            ["--label", "A", "--wait-timeout", "-1"],
            ["--label", "A", "--wait-timeout", "1", "--poll-interval", "0"],
        ]
    )
    func validation(arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try Focus.parse(arguments + ["--udid", Self.udid])
        }
    }

    @Test("focus is tvOS only, with a hint to tap by selector elsewhere", arguments: [SimulatorPlatform.iOS, .watchOS, .visionOS, .unknown])
    func tvOSOnly(platform: SimulatorPlatform) throws {
        do {
            try PlatformSupport.check(.focus, on: platform)
            Issue.record("Expected a refusal on \(platform)")
        } catch let error as CLIError {
            #expect(error.message == "Focus is only available on tvOS simulators (this simulator runs \(platform.phrase)); use `axe tap --label` or `axe tap --id` instead")
        }
        try PlatformSupport.check(.focus, on: .tvOS)
    }

    @Test("A missing simulator is not found before the focus platform check")
    func missingSimulator() {
        do {
            try PlatformSupport.check(.focus, simulatorUDID: Self.udid) { _ in nil }
            Issue.record("Expected not found")
        } catch let error as CLIError {
            #expect(error.message == CLIError.simulatorNotFound(udid: Self.udid).message)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}

@Suite("Batch focus step")
@MainActor
struct BatchFocusStepTests {
    @Test("focus is a batch step kind that is checked against the platform before any step runs")
    func preflight() throws {
        #expect(BatchStepKind(rawValue: "focus") == .focus)
        try Batch.checkSteps(["remote menu", "focus --label 'Screen Saver' --select", "focus --id AppCell"], udid: "SIMULATOR_UDID", on: .tvOS)
        do {
            try Batch.checkSteps(["focus --label General"], udid: "SIMULATOR_UDID", on: .watchOS)
            Issue.record("Expected a refusal")
        } catch let error as CLIError {
            #expect(error.message.hasPrefix("Step 1 failed: [focus]\nFocus is only available on tvOS simulators"))
        }
        #expect(throws: CLIError.self) {
            try Batch.checkSteps(["focus"], udid: "SIMULATOR_UDID", on: .tvOS)
        }
    }

    @Test("A focus step drops the perBatch snapshot")
    func invalidatesSnapshot() {
        let primitive = BatchPrimitive.focusNavigation(FocusRequest(query: .label("General")))
        #expect(primitive.invalidatesAccessibilitySnapshot)
        #expect(!primitive.invalidatesDisplayState)
    }

    @Test("A focus step checks the simulator first")
    func parsesFocusStep() async throws {
        let udid = "00000000-0000-0000-0000-000000000000"
        let context = BatchContext(simulatorUDID: udid, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
        do {
            _ = try await BatchStepParser.parseStepTokens(["focus", "--label", "General"], globalUDID: udid, context: context, logger: AxeLogger())
            Issue.record("Expected the missing simulator to fail the step")
        } catch let error as CLIError {
            #expect(error.message == CLIError.simulatorNotFound(udid: udid).message)
        }
    }
}
