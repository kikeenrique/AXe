import Testing
import Foundation

/// Drives a booted tvOS simulator through the system Settings app. Enabled with `AXE_E2E=1 AXE_TVOS_E2E=1`;
/// the simulator is `AXE_TVOS_SIMULATOR_UDID`, or the only booted tvOS simulator.
@Suite("tvOS Simulator Tests", .serialized, .enabled(if: isTVOSE2EEnabled))
struct TVOSTests {
    private func simulatorUDID() async throws -> String {
        try await TestHelpers.requirePlatformSimulatorUDID(.tvOS)
    }

    private func focusedLabel(_ roots: [UIElement]) -> String? {
        TestHelpers.flattened(roots).last { $0.focused == true }?.label
    }

    /// Settings relaunched on its root list, with a labelled element focused.
    @discardableResult
    private func launchSettings(_ udid: String) async throws -> [UIElement] {
        try await TestHelpers.relaunchSystemApp(E2EPlatform.tvOS.settingsBundleID, simulatorUDID: udid) { roots in
            focusedLabel(roots)?.isEmpty == false
        }
    }

    /// A button in the focused element's column, `offset` rows below it: a row `focus` has to press toward.
    private func rowBelowFocus(_ roots: [UIElement], offset: Int) throws -> String {
        let elements = TestHelpers.flattened(roots)
        let focused = try #require(elements.last { $0.focused == true })
        let focusedFrame = try #require(focused.frame)
        var seen = Set<String>()
        let below = elements
            .filter { element in
                guard element.type == "Button",
                      let label = element.label, !label.isEmpty, label != focused.label,
                      let frame = element.frame else { return false }
                // The focused row is drawn slightly larger, so compare horizontal centres.
                let centreOffset = (frame.x + frame.width / 2) - (focusedFrame.x + focusedFrame.width / 2)
                return abs(centreOffset) < 10 && frame.width > focusedFrame.width / 2
                    && frame.y > focusedFrame.y + focusedFrame.height / 2
            }
            .sorted { ($0.frame?.y ?? 0) < ($1.frame?.y ?? 0) }
            .compactMap(\.label)
            .filter { seen.insert($0).inserted }
        let label = try #require(below.isEmpty ? nil : below[min(offset, below.count) - 1], "No row below '\(focused.label ?? "")'")
        return label
    }

    @Test("list-simulators reports the tvOS platform")
    func listSimulatorsPlatform() async throws {
        let udid = try await simulatorUDID()
        let result = try await TestHelpers.runAxeCommand("list-simulators")
        let line = try #require(result.output.components(separatedBy: .newlines).first { $0.hasPrefix(udid) })
        #expect(line.hasSuffix("| Platform 'tvOS'"), "Unexpected line: \(line)")
    }

    @Test("describe-ui --focused prints the focused Settings row")
    func describeUIFocused() async throws {
        let udid = try await simulatorUDID()
        let roots = try await launchSettings(udid)

        let focused = try await TestHelpers.focusedElement(simulatorUDID: udid)
        #expect(focused.focused == true)
        #expect(focused.label == focusedLabel(roots))
        #expect(focused.children?.isEmpty ?? true, "--focused prints the element without its children")
    }

    @Test("remote arrows move focus and back")
    func remoteMovesFocus() async throws {
        let udid = try await simulatorUDID()
        let roots = try await launchSettings(udid)
        let start = try #require(focusedLabel(roots))

        try await TestHelpers.runAxeCommand("remote down", simulatorUDID: udid)
        try await TestHelpers.waitForFocus(simulatorUDID: udid, description: "focus to leave '\(start)'") { $0.label != start }

        try await TestHelpers.runAxeCommand("remote up", simulatorUDID: udid)
        try await TestHelpers.waitForFocus(simulatorUDID: udid, description: "focus to return to '\(start)'") { $0.label == start }
    }

    @Test("focus --label reaches a row, --select opens it, remote menu goes back")
    func focusSelectAndMenu() async throws {
        let udid = try await simulatorUDID()
        let roots = try await launchSettings(udid)
        let start = try #require(focusedLabel(roots))
        let target = try rowBelowFocus(roots, offset: 3)

        let focus = try await TestHelpers.runAxeCommand("focus --label \(TestHelpers.shellQuoted(target))", simulatorUDID: udid)
        #expect(focus.output.contains("Focused"), "Unexpected output: \(focus.output)")
        try await TestHelpers.waitForFocus(simulatorUDID: udid, description: "focus on '\(target)'") { $0.label == target }

        try await TestHelpers.runAxeCommand("focus --label \(TestHelpers.shellQuoted(target)) --select", simulatorUDID: udid)
        try await TestHelpers.waitForTree(simulatorUDID: udid, timeout: 5, description: "'\(target)' to open") { roots in
            !TestHelpers.flattened(roots).contains { $0.label == start }
        }

        try await TestHelpers.runAxeCommand("remote menu", simulatorUDID: udid)
        try await TestHelpers.waitForFocus(simulatorUDID: udid, description: "focus back on '\(target)'") { $0.label == target }
    }

    @Test("touch commands are refused with a pointer to remote", arguments: ["tap -x 100 -y 100", "tap --label General"])
    func touchIsRefused(command: String) async throws {
        let udid = try await simulatorUDID()
        let result = try await TestHelpers.runAxeCommandAllowFailure(command, simulatorUDID: udid)
        #expect(result.exitCode != 0)
        #expect(result.output.contains("use `axe remote`"), "Unexpected output: \(result.output)")
    }

    @Test("screenshot writes a TV-sized PNG")
    func screenshotWritesPNG() async throws {
        let udid = try await simulatorUDID()
        let output = try TestHelpers.e2eArtifactsDirectory().appendingPathComponent("axe-tvos-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }

        try await TestHelpers.runAxeCommand("screenshot --output \(TestHelpers.shellQuoted(output.path))", simulatorUDID: udid)

        let data = try Data(contentsOf: output)
        let size = try #require(TestHelpers.pngDimensions(data), "Output must be a PNG")
        #expect(data.count > 10_000)
        #expect(size.width >= 1280, "Unexpected width \(size.width)")
        #expect(abs(Double(size.width) / Double(size.height) - 16.0 / 9.0) < 0.05, "Expected 16:9, got \(size.width)x\(size.height)")
    }

    @Test("batch runs focus and remote steps, and refuses a touch step before sending anything")
    func batchFocusAndRemote() async throws {
        let udid = try await simulatorUDID()
        let roots = try await launchSettings(udid)
        let target = try rowBelowFocus(roots, offset: 2)
        let next = try rowBelowFocus(roots, offset: 3)
        let focusStep = "focus --label \"\(target)\""

        let result = try await TestHelpers.runAxeCommand(
            "batch --step \(TestHelpers.shellQuoted(focusStep)) --step 'remote down'",
            simulatorUDID: udid
        )
        #expect(result.output.contains("Batch completed successfully"), "Unexpected output: \(result.output)")
        try await TestHelpers.waitForFocus(simulatorUDID: udid, description: "focus on '\(next)'") { $0.label == next }

        let refused = try await TestHelpers.runAxeCommandAllowFailure(
            "batch --step 'remote up' --step 'tap -x 1 -y 1'",
            simulatorUDID: udid
        )
        #expect(refused.exitCode != 0)
        #expect(refused.output.contains("No step was run"), "Unexpected output: \(refused.output)")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(try await TestHelpers.focusedElement(simulatorUDID: udid).label == next, "The refused batch must not press up")
    }
}
