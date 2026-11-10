import Testing
import Foundation

/// Drives a booted watchOS simulator through the system Settings app. Enabled with `AXE_E2E=1 AXE_WATCHOS_E2E=1`;
/// the simulator is `AXE_WATCHOS_SIMULATOR_UDID`, or the only booted watchOS simulator.
@Suite("watchOS Simulator Tests", .serialized, .enabled(if: isWatchOSE2EEnabled))
struct WatchOSTests {
    /// A Settings list row: a labelled group about one row tall, as wide as most of the screen.
    private struct Row {
        let label: String
        let frame: UIElement.Frame
    }

    private func simulatorUDID() async throws -> String {
        try await TestHelpers.requirePlatformSimulatorUDID(.watchOS)
    }

    private func screenHeight(_ roots: [UIElement]) -> Double? {
        roots.first(where: { $0.type == "Application" })?.frame?.height
    }

    /// Rows fully on screen below the navigation bar, top to bottom, one per label.
    private func visibleRows(_ roots: [UIElement]) -> [Row] {
        guard let height = screenHeight(roots) else { return [] }
        var seen = Set<String>()
        return TestHelpers.flattened(roots)
            .compactMap { element -> Row? in
                guard element.type == "Group",
                      let label = element.label, !label.isEmpty,
                      let frame = element.frame,
                      frame.height >= 30, frame.height <= 90, frame.width >= 100,
                      frame.y >= 40, frame.y + frame.height <= height else {
                    return nil
                }
                return Row(label: label, frame: frame)
            }
            .sorted { $0.frame.y < $1.frame.y }
            .filter { seen.insert($0.label).inserted }
    }

    private func rowFrame(_ label: String, in roots: [UIElement]) -> UIElement.Frame? {
        TestHelpers.flattened(roots).first { element in
            element.type == "Group" && element.label == label && (element.frame?.height ?? 0) >= 30
        }?.frame
    }

    /// Settings relaunched at the top of its list, with at least two rows visible.
    @discardableResult
    private func launchSettings(_ udid: String) async throws -> [UIElement] {
        try await TestHelpers.relaunchSystemApp(E2EPlatform.watchOS.settingsBundleID, simulatorUDID: udid) { roots in
            visibleRows(roots).count >= 2
        }
    }

    @Test("list-simulators reports the watchOS platform")
    func listSimulatorsPlatform() async throws {
        let udid = try await simulatorUDID()
        let result = try await TestHelpers.runAxeCommand("list-simulators")
        let line = try #require(result.output.components(separatedBy: .newlines).first { $0.hasPrefix(udid) })
        #expect(line.hasSuffix("| Platform 'watchOS'"), "Unexpected line: \(line)")
    }

    @Test("describe-ui returns the Settings tree with children")
    func describeUIReturnsTree() async throws {
        let udid = try await simulatorUDID()
        try await launchSettings(udid)

        let roots = try await TestHelpers.describeUIRoots(simulatorUDID: udid)
        let application = try #require(roots.first { $0.type == "Application" })
        #expect(!(application.children ?? []).isEmpty, "The application root must have children")
        #expect(TestHelpers.flattened(roots).count >= 10)
        #expect(visibleRows(roots).count >= 2)
    }

    @Test("screenshot writes a watch-sized PNG")
    func screenshotWritesPNG() async throws {
        let udid = try await simulatorUDID()
        let output = try TestHelpers.e2eArtifactsDirectory().appendingPathComponent("axe-watchos-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }

        try await TestHelpers.runAxeCommand("screenshot --output \(TestHelpers.shellQuoted(output.path))", simulatorUDID: udid)

        let data = try Data(contentsOf: output)
        let size = try #require(TestHelpers.pngDimensions(data), "Output must be a PNG")
        #expect(data.count > 10_000)
        #expect((200...800).contains(size.width), "Unexpected width \(size.width)")
        #expect((200...900).contains(size.height), "Unexpected height \(size.height)")
        #expect(size.height >= size.width, "A watch screen is at least as tall as it is wide")
    }

    @Test("crown scrolls the list and waits for it to settle")
    func crownScrollsAndSettles() async throws {
        let udid = try await simulatorUDID()
        let before = try await launchSettings(udid)
        let row = try #require(visibleRows(before).first)

        let result = try await TestHelpers.runAxeCommand("crown --delta 50", simulatorUDID: udid)
        #expect(result.output.contains("settled in"), "Unexpected output: \(result.output)")

        let immediate = try await TestHelpers.describeUIRoots(simulatorUDID: udid)
        if let moved = rowFrame(row.label, in: immediate) {
            #expect(moved.y < row.frame.y - 5, "'\(row.label)' should move up, from y \(row.frame.y) to \(moved.y)")
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        let later = try await TestHelpers.describeUIRoots(simulatorUDID: udid)
        #expect(
            TestHelpers.layoutSignature(immediate) == TestHelpers.layoutSignature(later),
            "A settled crown scroll should leave nothing moving for the next command"
        )
    }

    @Test("crown --no-settle returns sooner than a settled rotation")
    func crownNoSettleReturnsSooner() async throws {
        let udid = try await simulatorUDID()
        try await launchSettings(udid)

        let clock = ContinuousClock()
        let settledStart = clock.now
        try await TestHelpers.runAxeCommand("crown --delta 50", simulatorUDID: udid)
        let settled = clock.now - settledStart

        let unsettledStart = clock.now
        let result = try await TestHelpers.runAxeCommand("crown --delta=-50 --no-settle", simulatorUDID: udid)
        let unsettled = clock.now - unsettledStart

        #expect(!result.output.contains("settled in"), "Unexpected output: \(result.output)")
        #expect(unsettled < settled, "--no-settle took \(unsettled), the settled rotation \(settled)")
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    @Test("coordinate tap opens a Settings row")
    func coordinateTapOpensRow() async throws {
        let udid = try await simulatorUDID()
        let roots = try await launchSettings(udid)
        let rows = visibleRows(roots)
        let target = try #require(rows.first)
        let sibling = try #require(rows.dropFirst().first)

        let x = Int((target.frame.x + target.frame.width / 2).rounded())
        let y = Int((target.frame.y + target.frame.height / 2).rounded())
        try await TestHelpers.runAxeCommand("tap -x \(x) -y \(y)", simulatorUDID: udid)

        try await TestHelpers.waitForTree(
            simulatorUDID: udid,
            timeout: 5,
            description: "'\(target.label)' to open, leaving '\(sibling.label)' behind"
        ) { roots in
            !TestHelpers.flattened(roots).contains { $0.label == sibling.label }
        }
    }

    @Test("button home leaves the app")
    func buttonHomeLeavesApp() async throws {
        let udid = try await simulatorUDID()
        let roots = try await launchSettings(udid)
        let appLabel = try #require(roots.first { $0.type == "Application" }?.label)

        try await TestHelpers.runAxeCommand("button home", simulatorUDID: udid)

        try await TestHelpers.waitForTree(simulatorUDID: udid, timeout: 5, description: "'\(appLabel)' to leave the screen") { roots in
            !roots.contains { $0.type == "Application" && $0.label == appLabel }
        }
    }

    @Test(
        "iOS and tvOS commands are refused before anything is sent",
        arguments: ["focus --label General", "remote up", "rotate landscape", "hinge open"]
    )
    func refusesOtherPlatformCommands(command: String) async throws {
        let udid = try await simulatorUDID()
        let result = try await TestHelpers.runAxeCommandAllowFailure(command, simulatorUDID: udid)
        #expect(result.exitCode != 0)
        #expect(result.output.contains("this simulator runs watchOS"), "Unexpected output: \(result.output)")
    }
}
