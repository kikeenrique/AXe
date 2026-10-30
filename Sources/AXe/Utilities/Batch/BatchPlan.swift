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
}

struct BatchPlan {
    let primitives: [BatchPrimitive]
}

