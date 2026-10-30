import Foundation
import FBSimulatorControl

enum BatchPrimitive {
    case hidMergeable(FBSimulatorHIDEvent)
    case hidBarrier(FBSimulatorHIDEvent)
    case hostSleep(TimeInterval)
    case physicalTap(point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?)
    /// A hinge or rotation change. Runs as a barrier and invalidates cached display and
    /// accessibility state, because it changes the coordinate space of later steps.
    case deviceState(DeviceStateAction)
}

struct BatchPlan {
    let primitives: [BatchPrimitive]
}

