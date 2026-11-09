import ArgumentParser
import Foundation

// MARK: - Settle Policy

/// How long, and how often, AXe reads the screen while it waits for moving content to stop.
struct UISettlePolicy: Equatable, Sendable {
    static let defaultTimeoutSeconds = 3.0
    static let maximumTimeoutSeconds = 60.0
    /// The pause between two reads; each read of the accessibility tree takes time of its own.
    static let defaultInterval: Duration = .milliseconds(100)

    let timeoutSeconds: Double
    let timeout: Duration
    let interval: Duration

    init(timeoutSeconds: Double = defaultTimeoutSeconds, interval: Duration = defaultInterval) {
        self.timeoutSeconds = timeoutSeconds
        timeout = .milliseconds(Int64((timeoutSeconds * 1000).rounded()))
        self.interval = interval
    }

    /// Throws unless `seconds` is a usable `--settle-timeout`.
    static func validateTimeout(_ seconds: Double, option: String = "--settle-timeout") throws {
        guard seconds.isFinite, seconds > 0, seconds <= maximumTimeoutSeconds else {
            throw ValidationError("\(option) must be more than 0 and at most \(Int(maximumTimeoutSeconds)) seconds.")
        }
    }
}

enum UISettleOutcome: Equatable, Sendable {
    /// Two consecutive snapshots were equal.
    case settled(elapsed: Duration, snapshots: Int)
    /// The timeout ran out while consecutive snapshots still differed.
    case timedOut(elapsed: Duration, snapshots: Int)
}

// MARK: - Settle Loop

enum UISettle {
    /// Reads `snapshot` every `policy.interval` until two consecutive snapshots are equal, or until
    /// `policy.timeout` has elapsed (measured by `elapsed`, from the start of the wait).
    ///
    /// The first snapshot is taken at once, so content that is already still settles after one
    /// interval and two reads. A timeout is an outcome, not an error: the caller decides whether
    /// to warn. Errors from `snapshot` and `sleep` (cancellation) propagate.
    static func waitUntilStable<Snapshot: Equatable>(
        policy: UISettlePolicy,
        snapshot: () async throws -> Snapshot,
        elapsed: () -> Duration,
        sleep: (Duration) async throws -> Void
    ) async throws -> UISettleOutcome {
        var previous = try await snapshot()
        var count = 1
        while true {
            if elapsed() >= policy.timeout {
                return .timedOut(elapsed: elapsed(), snapshots: count)
            }
            try await sleep(policy.interval)
            let current = try await snapshot()
            count += 1
            if current == previous {
                return .settled(elapsed: elapsed(), snapshots: count)
            }
            previous = current
        }
    }
}

// MARK: - Layout Snapshot

/// What a follow-up command reads from the accessibility tree: each element's type, label,
/// identifier, value, focus and frame, in tree order. Two equal signatures mean nothing a selector
/// or `describe-ui` reports has moved or changed between the reads.
struct AccessibilityLayoutSignature: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let type: String?
        let label: String?
        let identifier: String?
        let value: String?
        let isFocused: Bool
        let frame: AccessibilityElement.Frame?
    }

    let entries: [Entry]

    init(roots: [AccessibilityElement]) {
        entries = roots.flatMap { $0.flattened() }.map { element in
            Entry(
                type: element.type,
                label: element.AXLabel,
                identifier: element.AXUniqueId ?? element.AXIdentifier,
                value: element.AXValue,
                isFocused: element.isFocused,
                frame: element.frame
            )
        }
    }
}
