import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - HID Interactor


// Xcode 27 Beta 3 (27A5218g) Device Hub requires Resize Mode to be disabled for UI automation.
// With Resize Mode enabled, both DTUHID and legacy Indigo reported successful sends without
// delivering touches; with it disabled, the ui-interactions pass through this IDB path.
@MainActor
struct HIDInteractor {

    struct Session {
        let simulatorUDID: String
        let simulator: Simulator
        let hid: SimulatorHID
    }

    /// Configurable stabilization delay to ensure HID events are fully processed
    /// Can be set via AXE_HID_STABILIZATION_MS environment variable
    private static var stabilizationDelayMs: UInt64 {
        if let envValue = ProcessInfo.processInfo.environment["AXE_HID_STABILIZATION_MS"],
           let milliseconds = UInt64(envValue) {
            return min(milliseconds, 1000)
        }
        return 25
    }

    static func makeSession(for simulatorUDID: String, logger: AxeLogger) async throws -> Session {
        let simulator = try SimulatorSession.bootedSimulator(udid: simulatorUDID, logger: logger)
        logger.info().log("Simulator obtained: \(simulator.udid) (\(simulator.name)), state verified: booted")

        let bootIdentity = try HIDBroker.currentBootIdentity(simulatorUDID: simulatorUDID)
        // The transport follows the CoreSimulator version, as in IDB; `dtuhidd` itself starts on
        // demand when IDB connects, so its absence here is not a signal.
        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: bootIdentity,
            isDTUHIDSelected: HIDBroker.usesDTUHID(),
            now: Date.init,
            sleep: { delay in try await Task.sleep(for: .seconds(delay)) }
        )
        logger.info().log("Connecting to HID for simulator \(simulator.udid)...")
        // IDB shares one connection per simulator and drops it when the simulator changes state.
        let hid = try await simulator.hid.connect()
        let connectedBootIdentity = try HIDBroker.currentBootIdentity(simulatorUDID: simulatorUDID)
        guard HIDBroker.shouldReuseSession(
            sessionBootIdentity: bootIdentity,
            currentBootIdentity: connectedBootIdentity
        ) else {
            await simulator.hid.disconnect()
            throw CLIError(
                errorDescription: "Simulator \(simulatorUDID) restarted while AXe was connecting. Try the command again."
            )
        }
        return Session(simulatorUDID: simulatorUDID, simulator: simulator, hid: hid)
    }

    static func performHIDEvent(_ event: SimulatorHIDEvent, in session: Session, logger: AxeLogger) async throws {
        // Every touch path (tap, swipe, drag, slider, gesture, batch, and the hid-broker used by
        // `axe touch`) passes through here. Touch coordinates are interface points of the active
        // display; IDB routes them to that display and rotates them to the panel's native space.
        logger.info().log("Performing HID event...")
        try await session.hid.send(event: event, logger: logger, on: .active)
        logger.info().log("HID event performed successfully.")

        if stabilizationDelayMs > 0 {
            logger.info().log("Applying stabilization delay of \(stabilizationDelayMs)ms...")
            try await Task.sleep(nanoseconds: stabilizationDelayMs * 1_000_000)
        }
    }

    static func performHIDEvent(_ event: SimulatorHIDEvent, for simulatorUDID: String, logger: AxeLogger) async throws {
        let session = try await makeSession(for: simulatorUDID, logger: logger)
        try await performHIDEvent(event, in: session, logger: logger)
    }

    static func makeCompositeDragEvent(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        duration: TimeInterval,
        steps: Int,
        initialHold: TimeInterval,
        finalHold: TimeInterval
    ) throws -> SimulatorHIDEvent {
        guard duration >= 0 else {
            throw CLIError(errorDescription: "Drag duration must be non-negative.")
        }
        guard steps > 0 else {
            throw CLIError(errorDescription: "Drag steps must be greater than 0.")
        }
        guard initialHold >= 0, finalHold >= 0 else {
            throw CLIError(errorDescription: "Drag hold durations must be non-negative.")
        }

        let movePoints = try compositeDragMovePoints(from: start, to: end, steps: steps)
        let stepDelay = duration / Double(steps)
        var events: [SimulatorHIDEvent] = [
            .touch(direction: .down, x: start.x, y: start.y),
            .delay(initialHold)
        ]

        for point in movePoints {
            events.append(.delay(stepDelay))
            events.append(.touch(direction: .down, x: point.x, y: point.y))
        }

        events.append(.delay(finalHold))
        events.append(.touch(direction: .up, x: end.x, y: end.y))

        return .composite(events)
    }

    static func compositeDragMovePoints(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        steps: Int
    ) throws -> [(x: Double, y: Double)] {
        guard steps > 0 else {
            throw CLIError(errorDescription: "Drag steps must be greater than 0.")
        }

        return (1...steps).map { step in
            let progress = Double(step) / Double(steps)
            return (
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
        }
    }

    static func performCompositeDrag(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        duration: TimeInterval,
        steps: Int,
        initialHold: TimeInterval,
        finalHold: TimeInterval,
        for simulatorUDID: String,
        logger: AxeLogger
    ) async throws {
        let event = try makeCompositeDragEvent(
            from: start,
            to: end,
            duration: duration,
            steps: steps,
            initialHold: initialHold,
            finalHold: finalHold
        )
        try await performHIDEvent(event, for: simulatorUDID, logger: logger)
    }

    static func performPhysicalTap(
        at point: (x: Double, y: Double),
        preDelay: Double?,
        postDelay: Double?,
        for simulatorUDID: String,
        logger: AxeLogger
    ) async throws {
        let session = try await makeSession(for: simulatorUDID, logger: logger)
        try await performPhysicalTap(at: point, preDelay: preDelay, postDelay: postDelay, in: session, logger: logger)
    }

    static func performPhysicalTap(
        at point: (x: Double, y: Double),
        preDelay: Double?,
        postDelay: Double?,
        in session: Session,
        logger: AxeLogger
    ) async throws {
        if let preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            try await Task.sleep(for: .seconds(preDelay))
        }

        let touchDownEvent = SimulatorHIDEvent.touch(direction: .down, x: point.x, y: point.y)
        let touchUpEvent = SimulatorHIDEvent.touch(direction: .up, x: point.x, y: point.y)
        var didTouchDown = false

        do {
            try await performHIDEvent(touchDownEvent, in: session, logger: logger)
            didTouchDown = true
            try await Task.sleep(for: .seconds(TapTiming.defaultHoldDuration))
            try await performHIDEvent(touchUpEvent, in: session, logger: logger)
            didTouchDown = false
        } catch {
            if didTouchDown {
                // Never replay touch-down after an ambiguous failure. A best-effort touch-up can
                // only release possible held state; it cannot produce a second tap by itself.
                try? await performHIDEvent(touchUpEvent, in: session, logger: logger)
            }
            throw error
        }

        if let postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            try await Task.sleep(for: .seconds(postDelay))
        }
    }
}
