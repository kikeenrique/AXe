import Foundation
import FBSimulatorControl

enum BatchPrimitive {
    case hidMergeable(SimulatorHIDEvent)
    case hidBarrier(SimulatorHIDEvent)
    case hostSleep(TimeInterval)
    case physicalTap(point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?)
    /// A hinge or rotation change. Runs as a barrier and invalidates cached display and
    /// accessibility state, because it changes the coordinate space of later steps.
    case deviceState(DeviceStateAction)
    /// A hardware button press. Runs as a barrier so that an Apple Pay press refused by IDB can be
    /// resent as two side-button presses (see `ButtonType.perform`).
    case buttonPress(ButtonType, duration: Double?)
    /// A Digital Crown rotation (watchOS). Runs as a barrier: IDB sends it over the scroll service,
    /// a connection of its own, and returns once the simulator has taken every report.
    case crownRotation(CrownRotation)

    /// Whether the primitive changes the display layout (fold, rotation), so cached display state
    /// must be re-read.
    var invalidatesDisplayState: Bool {
        if case .deviceState = self { return true }
        return false
    }

    /// Whether the primitive moves on-screen elements in a way the runner knows about (fold,
    /// rotation, Digital Crown scroll), so a `--ax-cache perBatch` snapshot must be dropped. Touch
    /// steps (taps, swipes, gestures) are merged HID events and keep the snapshot, as before; use
    /// `--ax-cache perStep` when they change the UI.
    var invalidatesAccessibilitySnapshot: Bool {
        switch self {
        case .deviceState, .crownRotation:
            return true
        case .hidMergeable, .hidBarrier, .hostSleep, .physicalTap, .buttonPress:
            return false
        }
    }
}

struct BatchPlan {
    let primitives: [BatchPrimitive]
}

