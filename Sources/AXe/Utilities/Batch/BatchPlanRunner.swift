import Foundation
import FBSimulatorControl

@MainActor
struct BatchPlanRunner {
    let session: HIDInteractor.Session
    let logger: AxeLogger
    var context: BatchContext?

    func run(_ plan: BatchPlan) async throws {
        var pendingMergeable: [SimulatorHIDEvent] = []

        func flushPending() async throws {
            guard !pendingMergeable.isEmpty else { return }
            let event = pendingMergeable.count == 1 ? pendingMergeable[0] : SimulatorHIDEvent.composite(pendingMergeable)
            try await HIDInteractor.performHIDEvent(event, in: session, logger: logger)
            pendingMergeable.removeAll(keepingCapacity: true)
        }

        for primitive in plan.primitives {
            switch primitive {
            case .hidMergeable(let event):
                pendingMergeable.append(event)
            case .hidBarrier(let event):
                try await flushPending()
                // A barrier prevents event coalescing; failures propagate without replaying
                // this event or any earlier event in the batch.
                try await HIDInteractor.performHIDEvent(event, in: session, logger: logger)
            case .hostSleep(let seconds):
                try await flushPending()
                guard seconds > 0 else { continue }

                try await Task.sleep(for: .seconds(seconds))
            case .physicalTap(let point, let preDelay, let postDelay):
                try await flushPending()
                try await HIDInteractor.performPhysicalTap(
                    at: point,
                    preDelay: preDelay,
                    postDelay: postDelay,
                    in: session,
                    logger: logger
                )
            case .buttonPress(let button, let duration):
                try await flushPending()
                try await button.perform(duration: duration, in: session, logger: logger)
            case .crownRotation(let rotation):
                try await flushPending()
                // The rotation scrolls the content, so element frames in a cached tree are stale.
                defer { invalidateCaches(after: primitive) }
                try await rotation.perform(on: session.simulator, logger: logger)
            case .deviceState(let action):
                try await flushPending()
                defer { invalidateCaches(after: primitive) }
                if let warning = try await FoldableDevice.perform(action, simulator: session.simulator, logger: logger) {
                    print("Warning: \(warning)", to: &standardError)
                }
            }
        }

        try await flushPending()
    }

    private func invalidateCaches(after primitive: BatchPrimitive) {
        Self.invalidateCaches(after: primitive, context: context)
    }

    /// Drops the cached state that `primitive` makes stale (see `BatchPrimitive.invalidatesDisplayState`
    /// and `invalidatesAccessibilitySnapshot`). The runner calls it whether or not the primitive
    /// succeeded, since a failed fold, rotation or crown turn may still have changed the screen.
    static func invalidateCaches(after primitive: BatchPrimitive, context: BatchContext?) {
        if primitive.invalidatesDisplayState {
            SimulatorDisplays.invalidateCachedState()
        }
        if primitive.invalidatesAccessibilitySnapshot {
            context?.invalidateAccessibilityCache()
        }
    }
}
