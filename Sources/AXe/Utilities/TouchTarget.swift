import AXeCore
import CoreGraphics
import FBSimulatorControl
import Foundation

// MARK: - Touch Target

/// The display that touches are delivered to, from devicectl state.
///
/// Built from the active display of a multi-display (foldable) simulator. `isMain` is true for
/// display IDs 0 and 1, which reach the main touchscreen without an explicit target; touches to
/// the main display keep the pre-foldable path and send no target, so their wire format is unchanged.
///
/// Every coordinate AXe receives (`-x/-y`, swipe, drag, gesture, selector activation points) is an
/// interface point of the active display, as a screenshot shows it. `nativePoint(fromInterface:)`
/// converts it to the panel's native portrait points, which DTUHID normalises against the target.
struct TouchTarget: Equatable {
    static let unknownDisplayMessage = "AXe could not determine which display of the foldable simulator is active, so no touch was sent. Confirm the simulator is booted and try again."

    let displayID: Int
    /// Native portrait size in pixels.
    let nativePixelSize: SimulatorDisplay.Size
    let pointScale: Double
    let rotation: SimulatorDisplay.Rotation
    let isMain: Bool
    /// Window sizes, in points or pixels, that belong to other displays or to pixel-sized backing
    /// windows. Accessibility windows of these sizes are not part of the active panel.
    let foreignWindowSizes: [SimulatorDisplay.Size]

    init(
        displayID: Int,
        nativePixelSize: SimulatorDisplay.Size,
        pointScale: Double,
        rotation: SimulatorDisplay.Rotation,
        isMain: Bool,
        foreignWindowSizes: [SimulatorDisplay.Size] = []
    ) {
        self.displayID = displayID
        self.nativePixelSize = nativePixelSize
        self.pointScale = pointScale
        self.rotation = rotation
        self.isMain = isMain
        self.foreignWindowSizes = foreignWindowSizes
    }

    /// Native portrait size in points: `nativeSize / pointScale`.
    var nativePointSize: SimulatorDisplay.Size {
        SimulatorDisplay.Size(width: nativePixelSize.width / pointScale, height: nativePixelSize.height / pointScale)
    }

    /// Interface size in points, as a screenshot of the display shows it.
    var interfacePointSize: SimulatorDisplay.Size {
        let native = nativePointSize
        switch rotation {
        case .rot0, .rot180:
            return native
        case .rot90, .rot270:
            return SimulatorDisplay.Size(width: native.height, height: native.width)
        }
    }

    /// The interface bounds of the display in points.
    var interfaceBounds: AccessibilityElement.Frame {
        let size = interfacePointSize
        return AccessibilityElement.Frame(x: 0, y: 0, width: size.width, height: size.height)
    }

    /// idb's display target, or `nil` for the main display (unchanged wire output).
    var hidTarget: FBSimulatorHIDDisplayTarget? {
        guard !isMain else { return nil }
        return FBSimulatorHIDDisplayTarget(
            displayID: UInt32(displayID),
            nativeSize: CGSize(width: nativePixelSize.width, height: nativePixelSize.height),
            scale: Float(pointScale)
        )
    }

    // MARK: Conversions

    /// Interface point → native portrait point. rot90: `(y, H - x)`; rot270: `(W - y, x)`;
    /// rot180: `(W - x, H - y)`; rot0: identity. `W`/`H` are the native point size.
    func nativePoint(fromInterface point: (x: Double, y: Double)) -> (x: Double, y: Double) {
        let size = nativePointSize
        return OrientationCoordinateMath.translateToPhysical(
            x: point.x,
            y: point.y,
            orientation: rotation.simulatorOrientation.coreOrientation,
            portraitWidth: size.width,
            portraitHeight: size.height
        )
    }

    /// Native portrait point → interface point; the inverse of `nativePoint(fromInterface:)`.
    func interfacePoint(fromNative point: (x: Double, y: Double)) -> (x: Double, y: Double) {
        let size = nativePointSize
        switch rotation {
        case .rot0:
            return point
        case .rot90:
            return (x: size.height - point.y, y: point.x)
        case .rot180:
            return (x: size.width - point.x, y: size.height - point.y)
        case .rot270:
            return (x: point.y, y: size.width - point.x)
        }
    }

    /// Converts a native-space accessibility frame to the interface frame it covers on screen.
    func interfaceRect(fromNative frame: AccessibilityElement.Frame) -> AccessibilityElement.Frame {
        let first = interfacePoint(fromNative: (x: frame.x, y: frame.y))
        let second = interfacePoint(fromNative: (x: frame.x + frame.width, y: frame.y + frame.height))
        return AccessibilityElement.Frame(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    /// The point as a fraction of the native panel, which is what DTUHID sends on the wire.
    func normalized(nativePoint point: (x: Double, y: Double)) -> (x: Double, y: Double) {
        let size = nativePointSize
        return (x: point.x / size.width, y: point.y / size.height)
    }

    func containsNativePoint(_ point: (x: Double, y: Double)) -> Bool {
        let size = nativePointSize
        return point.x >= 0 && point.y >= 0 && point.x <= size.width && point.y <= size.height
    }

    /// Converts an interface point and refuses one that lands outside the panel: such a touch
    /// would go nowhere (or to the panel edge) while the command reports success.
    func checkedNativePoint(fromInterface point: (x: Double, y: Double)) throws -> (x: Double, y: Double) {
        let native = nativePoint(fromInterface: point)
        guard containsNativePoint(native) else {
            let interface = interfacePointSize
            throw CLIError(
                errorDescription: "Point (\(Self.format(point.x)), \(Self.format(point.y))) is outside display \(displayID), which is \(Self.format(interface.width))x\(Self.format(interface.height)) points in its current orientation (native point (\(Self.format(native.x)), \(Self.format(native.y))) of \(Self.format(nativePointSize.width))x\(Self.format(nativePointSize.height))). No touch was sent. Take coordinates from `axe screenshot` of the active display (pixels divided by \(Self.format(pointScale)))."
            )
        }
        return native
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    // MARK: Accessibility windows

    /// The accessibility tree of the active panel, with every frame in interface points.
    ///
    /// On an unfolded foldable, SpringBoard exposes the windows of both panels (and pixel-sized
    /// backing windows) under one application element, so every home-screen label matches twice.
    /// Direct children of each root whose frame size matches `foreignWindowSizes` (either
    /// orientation) are removed.
    ///
    /// The frame space is decided per root (measured on the Duo inner panel): SpringBoard's
    /// application element reports another display's size (the cover's 466x678) and its windows
    /// carry native portrait frames, while an app's application element reports the panel size and
    /// its windows carry interface frames. Every remaining window under a root whose own frame is
    /// foreign-sized is converted from native to interface space. A root without a frame falls back
    /// to the window shape: a native-shaped window on a quarter-turned panel is converted.
    ///
    /// A root whose windows all belong to other displays is dropped.
    ///
    /// - Throws: when the tree has windows but none of them belongs to the active panel (for
    ///   example a tree read while the panel switched); resolving against the other panel's windows
    ///   would bring back double matches or convert the wrong coordinates.
    func activePanelRoots(_ roots: [AccessibilityElement]) throws -> [AccessibilityElement] {
        guard !isMain else { return roots }
        var panelRoots: [AccessibilityElement] = []
        var hasWindows = false
        var keptWindows = false
        for root in roots {
            guard let children = root.children, !children.isEmpty else {
                panelRoots.append(root)
                continue
            }
            hasWindows = true
            let kept = children.filter { !isForeignSized($0.frame) }
            guard !kept.isEmpty else { continue }
            keptWindows = true
            panelRoots.append(root.replacingChildren(kept.map { interfaceWindow($0, under: root) }))
        }
        guard keptWindows || !hasWindows else {
            throw CLIError(
                errorDescription: "The accessibility tree has no window on display \(displayID), the active display; it may have been read while the simulator folded or unfolded. No touch was sent. Run `axe posture` and try again."
            )
        }
        return panelRoots
    }

    /// True when the frames of `window` (a direct child of `root`) are in native portrait space.
    func isNativeSpaceWindow(_ window: AccessibilityElement, under root: AccessibilityElement) -> Bool {
        guard rotation != .rot0 else { return false }
        if let rootFrame = root.frame {
            return isForeignSized(rootFrame)
        }
        guard rotation == .rot90 || rotation == .rot270, let frame = window.frame else { return false }
        return Self.sizeMatches(frame, nativePointSize)
    }

    private func interfaceWindow(_ window: AccessibilityElement, under root: AccessibilityElement) -> AccessibilityElement {
        guard isNativeSpaceWindow(window, under: root) else { return window }
        return window.mappingFrames { interfaceRect(fromNative: $0) }
    }

    private func isForeignSized(_ frame: AccessibilityElement.Frame?) -> Bool {
        guard let frame else { return false }
        return foreignWindowSizes.contains { size in
            Self.sizeMatches(frame, size) || Self.sizeMatches(frame, SimulatorDisplay.Size(width: size.height, height: size.width))
        }
    }

    private static func sizeMatches(_ frame: AccessibilityElement.Frame, _ size: SimulatorDisplay.Size) -> Bool {
        abs(frame.width - size.width) < 0.5 && abs(frame.height - size.height) < 0.5
    }

    // MARK: Resolution

    /// The touch target for devicectl state.
    ///
    /// - Returns: `nil` without state (non-foldable, or `AXE_DISPLAY_PROBE=never`) or for a single
    ///   display, and for a main display without geometry (the main path needs none).
    /// - Throws: when the active display of a foldable cannot be determined, or a non-main display
    ///   lacks the orientation and size needed to convert coordinates.
    static func resolve(state: SimulatorDisplayState?) throws -> TouchTarget? {
        guard let state, state.isMultiDisplay else { return nil }
        guard let active = state.activeDisplay else {
            throw CLIError(errorDescription: unknownDisplayMessage)
        }
        let isMain = active.displayId <= 1
        guard let rotation = active.currentRotation,
              let nativeSize = active.nativeSize,
              let pointScale = active.pointScale,
              pointScale > 0, nativeSize.width > 0, nativeSize.height > 0 else {
            if isMain { return nil }
            throw CLIError(
                errorDescription: "AXe could not convert touch coordinates because devicectl did not report the orientation and size of display \(active.displayId) (\(active.name))."
            )
        }
        let activePoints = active.nativeSizePoints
        var foreign: [SimulatorDisplay.Size] = []
        for display in state.displays {
            if let pixels = display.nativeSize {
                foreign.append(pixels)
            }
            if display.displayId != active.displayId, let points = display.nativeSizePoints, points != activePoints {
                foreign.append(points)
            }
        }
        return TouchTarget(
            displayID: active.displayId,
            nativePixelSize: nativeSize,
            pointScale: pointScale,
            rotation: rotation,
            isMain: isMain,
            foreignWindowSizes: foreign
        )
    }

    /// The non-main target for a display state; `nil` when touches take the main-display path.
    static func nonMainTarget(state: SimulatorDisplayState?) throws -> TouchTarget? {
        try resolve(state: state).flatMap { $0.isMain ? nil : $0 }
    }

    /// The target for a simulator that needs an explicit display target: a non-main active
    /// display. `nil` when touches take the main-display path.
    @MainActor
    static func nonMainTarget(forSimulatorUDID simulatorUDID: String, logger: AxeLogger) async throws -> TouchTarget? {
        try nonMainTarget(state: await SimulatorDisplays.state(forSimulatorUDID: simulatorUDID, logger: logger))
    }

    @MainActor
    static func nonMainTarget(for simulator: FBSimulator, logger: AxeLogger) async throws -> TouchTarget? {
        try nonMainTarget(state: await SimulatorDisplays.state(for: simulator, logger: logger))
    }
}

// MARK: - Touch Routing

/// Decides where a touch goes: touches to a non-main display are routed with idb's DTUHID display
/// target; the main display keeps the untargeted path.
enum TouchRouting {
    static let probeDisabledWarning = "Warning: \(DisplayProbePolicy.environmentKey)=never disables display detection on this foldable simulator, so touches go to the cover display even while the inner display is active."

    @MainActor private static var didWarnProbeDisabled = false

    static func indigoTransportMessage(displayID: Int) -> String {
        "AXe can deliver touches to display \(displayID) of a foldable simulator only over the DTUHID input transport, and this simulator uses the legacy Indigo transport, which reaches only the cover display. Fold the simulator with `axe hinge close` so the cover display is active."
    }

    /// The idb display target for a resolved touch target and transport.
    ///
    /// - `nil` target or main display → `nil` (unchanged main-display behaviour).
    /// - non-main display over DTUHID → the display target.
    /// - non-main display over Indigo → error (Indigo reaches only the main touchscreen).
    static func hidTarget(
        for target: TouchTarget?,
        transport: FBSimulatorHIDTransportType
    ) throws -> FBSimulatorHIDDisplayTarget? {
        guard let target, !target.isMain else { return nil }
        guard transport == .dtuhid else {
            throw CLIError(errorDescription: indigoTransportMessage(displayID: target.displayID))
        }
        return target.hidTarget
    }

    /// The idb display target from a display-state lookup: a devicectl failure or an
    /// undeterminable active display is an error; no state (non-foldable, `AXE_DISPLAY_PROBE=never`)
    /// keeps the main-display behaviour.
    static func hidTarget(
        transport: FBSimulatorHIDTransportType,
        state: () async throws -> SimulatorDisplayState?
    ) async throws -> FBSimulatorHIDDisplayTarget? {
        try hidTarget(for: TouchTarget.nonMainTarget(state: await state()), transport: transport)
    }

    /// The idb display target for touches sent in `session`, from the cached display state.
    @MainActor
    static func hidTarget(for session: HIDInteractor.Session, logger: AxeLogger) async throws -> FBSimulatorHIDDisplayTarget? {
        warnIfProbeDisabled(for: session.simulator)
        let target: FBSimulatorHIDDisplayTarget?
        do {
            target = try await hidTarget(transport: session.hid.transportType) {
                try await SimulatorDisplays.state(for: session.simulator, logger: logger)
            }
        } catch {
            logger.error().log("Touch blocked: \(error.localizedDescription)")
            throw error
        }
        if let target {
            logger.info().log("Routing touches to \(target)")
        }
        return target
    }

    /// Prints `probeDisabledWarning` once per process on a foldable when the probe is disabled.
    @MainActor
    static func warnIfProbeDisabled(for simulator: FBSimulator) {
        guard !didWarnProbeDisabled,
              SimulatorDisplays.policy == .never,
              SimulatorDisplays.isFoldable(simulator) else { return }
        didWarnProbeDisabled = true
        print(probeDisabledWarning, to: &standardError)
    }
}
