import ArgumentParser
import Foundation
import Testing
@testable import AXe

/// A clock that only moves when the settle loop sleeps.
@MainActor
private final class FakeClock {
    var now: Duration = .zero
    var sleeps: [Duration] = []

    func sleep(_ duration: Duration) {
        sleeps.append(duration)
        now += duration
    }
}

@Suite("UI settle loop")
@MainActor
struct UISettleLoopTests {
    private let policy = UISettlePolicy(timeoutSeconds: 1, interval: .milliseconds(100))

    private func run(_ snapshots: [Int], clock: FakeClock? = nil) async throws -> UISettleOutcome {
        let clock = clock ?? FakeClock()
        var remaining = snapshots
        return try await UISettle.waitUntilStable(
            policy: policy,
            snapshot: { remaining.count > 1 ? remaining.removeFirst() : remaining[0] },
            elapsed: { clock.now },
            sleep: { clock.sleep($0) }
        )
    }

    @Test("Content that is already still settles after two reads and one interval")
    func alreadyStill() async throws {
        let clock = FakeClock()
        #expect(try await run([7, 7], clock: clock) == .settled(elapsed: .milliseconds(100), snapshots: 2))
        #expect(clock.sleeps == [.milliseconds(100)])
    }

    @Test("Reads continue until two consecutive reads match")
    func movingThenStill() async throws {
        #expect(try await run([1, 2, 3, 3, 3]) == .settled(elapsed: .milliseconds(300), snapshots: 4))
        // A value seen before but not consecutively does not count as settled.
        #expect(try await run([1, 2, 1, 2, 2]) == .settled(elapsed: .milliseconds(400), snapshots: 5))
    }

    @Test("Content that never stops times out at the timeout without throwing")
    func timesOut() async throws {
        var counter = 0
        let clock = FakeClock()
        let outcome = try await UISettle.waitUntilStable(
            policy: UISettlePolicy(timeoutSeconds: 0.3, interval: .milliseconds(100)),
            snapshot: { () -> Int in
                counter += 1
                return counter
            },
            elapsed: { clock.now },
            sleep: { clock.sleep($0) }
        )
        #expect(outcome == .timedOut(elapsed: .milliseconds(300), snapshots: 4))
        #expect(clock.sleeps.count == 3)
    }

    @Test("A read error propagates")
    func readError() async {
        await #expect(throws: CLIError.self) {
            _ = try await UISettle.waitUntilStable(
                policy: policy,
                snapshot: { () async throws -> Int in throw CLIError(errorDescription: "no tree") },
                elapsed: { .zero },
                sleep: { _ in }
            )
        }
    }

    @Test("The policy keeps the timeout in seconds and as a duration")
    func policyDurations() {
        let policy = UISettlePolicy(timeoutSeconds: 1.5)
        #expect(policy.timeout == .milliseconds(1500))
        #expect(policy.timeoutSeconds == 1.5)
        #expect(policy.interval == UISettlePolicy.defaultInterval)
        #expect(UISettlePolicy().timeoutSeconds == 3)
    }
}

@Suite("Accessibility layout signature")
struct AccessibilityLayoutSignatureTests {
    private func roots(_ json: String) throws -> [AccessibilityElement] {
        try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
    }

    @Test("Key order does not matter; frames, labels and structure do")
    func equality() throws {
        let a = try roots(#"[{"type":"Application","frame":{"x":0,"y":0,"width":187,"height":223},"children":[{"type":"Button","AXLabel":"General","frame":{"x":2,"y":49,"width":183,"height":51}}]}]"#)
        let reordered = try roots(#"[{"children":[{"frame":{"height":51,"width":183,"y":49,"x":2},"AXLabel":"General","type":"Button"}],"frame":{"y":0,"x":0,"height":223,"width":187},"type":"Application"}]"#)
        let scrolled = try roots(#"[{"type":"Application","frame":{"x":0,"y":0,"width":187,"height":223},"children":[{"type":"Button","AXLabel":"General","frame":{"x":2,"y":33,"width":183,"height":51}}]}]"#)
        let relabelled = try roots(#"[{"type":"Application","frame":{"x":0,"y":0,"width":187,"height":223},"children":[{"type":"Button","AXLabel":"Focus","frame":{"x":2,"y":49,"width":183,"height":51}}]}]"#)

        #expect(AccessibilityLayoutSignature(roots: a) == AccessibilityLayoutSignature(roots: reordered))
        #expect(AccessibilityLayoutSignature(roots: a) != AccessibilityLayoutSignature(roots: scrolled))
        #expect(AccessibilityLayoutSignature(roots: a) != AccessibilityLayoutSignature(roots: relabelled))
        #expect(AccessibilityLayoutSignature(roots: a).entries.count == 2)
    }
}

@Suite("Crown settle options")
struct CrownSettleOptionTests {
    private static let udid = "00000000-0000-0000-0000-000000000000"

    @Test("Settling is on by default with a 3 s timeout")
    func defaults() throws {
        let crown = try Crown.parse(["--delta", "50", "--udid", Self.udid])
        #expect(crown.settlePolicy == UISettlePolicy(timeoutSeconds: 3))
    }

    @Test("--no-settle turns it off; --settle-timeout sets the bound")
    func options() throws {
        #expect(try Crown.parse(["--delta", "50", "--no-settle", "--udid", Self.udid]).settlePolicy == nil)
        #expect(try Crown.parse(["--delta", "50", "--settle-timeout", "1.5", "--udid", Self.udid]).settlePolicy?.timeout == .milliseconds(1500))
    }

    @Test(
        "Out-of-range or conflicting settle options are refused",
        arguments: [
            ["--settle-timeout", "0"],
            ["--settle-timeout", "-1"],
            ["--settle-timeout", "61"],
            ["--settle-timeout", "nan"],
            ["--settle-timeout", "2", "--no-settle"],
        ]
    )
    func validation(arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try Crown.parse(["--delta", "50"] + arguments + ["--udid", Self.udid])
        }
    }

    @Test("A timeout warns, naming the bound; a settled scroll does not")
    func warnings() throws {
        let policy = UISettlePolicy(timeoutSeconds: 0.5)
        let warning = try #require(CrownRotation.settleWarning(for: .timedOut(elapsed: .milliseconds(520), snapshots: 3), policy: policy))
        #expect(warning.hasPrefix("Warning: the content was still moving 0.5 s after the Digital Crown rotation (--settle-timeout)"))
        #expect(warning.hasSuffix("The rotation was sent."))
        #expect(CrownRotation.settleWarning(for: .settled(elapsed: .milliseconds(300), snapshots: 3), policy: policy) == nil)
        #expect(CrownRotation.settleReadFailureWarning(CLIError(errorDescription: "no tree")).contains("(no tree)"))
    }

    @Test("The success line reports how long the content took to settle")
    func suffix() {
        #expect(CrownRotation.settleSuffix(for: .settled(elapsed: .milliseconds(1040), snapshots: 6)) == " (settled in 1.0 s)")
        #expect(CrownRotation.settleSuffix(for: .timedOut(elapsed: .seconds(3), snapshots: 20)).isEmpty)
        #expect(CrownRotation.settleSuffix(for: nil).isEmpty)
    }

    @Test("crown --help documents the settle wait")
    func help() {
        let discussion = Crown.configuration.discussion
        #expect(discussion.contains("--settle-timeout"))
        #expect(discussion.contains("--no-settle"))
    }

    @Test("Batch crown steps take the settle options and check them before any step runs")
    func batchPreflight() throws {
        try Batch.checkSteps(["crown --delta 50 --no-settle", "crown --delta=-50 --settle-timeout 1"], udid: "SIMULATOR_UDID", on: .watchOS)
        #expect(throws: CLIError.self) {
            try Batch.checkSteps(["crown --delta 50 --settle-timeout 0"], udid: "SIMULATOR_UDID", on: .watchOS)
        }
    }
}
