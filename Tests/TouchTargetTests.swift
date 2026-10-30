import FBSimulatorControl
import Foundation
import Testing
@testable import AXe

// Geometry of the iPhone Duo inner panel (Xcode 27.2): 2007x2853 px, scale 3, 669x951 pt native
// portrait. Fixtures in Fixtures/devicectl use placeholder UUIDs.

private func fixtureState(_ name: String) throws -> SimulatorDisplayState {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/devicectl")
    )
    return try SimulatorDisplayState.decode(from: Data(contentsOf: url))
}

private func innerTarget(_ rotation: SimulatorDisplay.Rotation) -> TouchTarget {
    TouchTarget(
        displayID: 3,
        nativePixelSize: SimulatorDisplay.Size(width: 2007, height: 2853),
        pointScale: 3,
        rotation: rotation,
        isMain: false,
        foreignWindowSizes: [
            SimulatorDisplay.Size(width: 466, height: 678),
            SimulatorDisplay.Size(width: 1398, height: 2034),
            SimulatorDisplay.Size(width: 2007, height: 2853),
        ]
    )
}

private func decodeElements(_ json: String) throws -> [AccessibilityElement] {
    try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
}

private func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.01) {
    #expect(abs(actual - expected) < tolerance, "\(actual) != \(expected)")
}

@Suite("Touch target")
struct TouchTargetTests {
    @Test("Unfolded Duo resolves the inner display with its native geometry")
    func unfoldedResolvesInner() throws {
        let target = try #require(try TouchTarget.resolve(state: fixtureState("duo-unfolded")))

        #expect(!target.isMain)
        #expect(target.displayID == 3)
        #expect(target.rotation == .rot90)
        #expect(target.nativePointSize == SimulatorDisplay.Size(width: 669, height: 951))
        #expect(target.interfacePointSize == SimulatorDisplay.Size(width: 951, height: 669))

        let hid = try #require(target.hidTarget)
        #expect(hid.displayID == 3)
        #expect(hid.nativeSize == CGSize(width: 2007, height: 2853))
        #expect(hid.scale == 3)
    }

    @Test("Main and non-foldable displays get no idb target")
    func mainHasNoHIDTarget() throws {
        let folded = try #require(try TouchTarget.resolve(state: fixtureState("duo-folded")))
        #expect(folded.isMain)
        #expect(folded.hidTarget == nil)
        #expect(try TouchTarget.nonMainTarget(state: fixtureState("duo-folded")) == nil)

        #expect(try TouchTarget.resolve(state: fixtureState("single-display")) == nil)
        #expect(try TouchTarget.resolve(state: nil) == nil)
    }

    @Test("An undeterminable active display throws")
    func unknownActiveDisplayThrows() {
        let state = SimulatorDisplayState(displays: [
            SimulatorDisplay(
                displayId: 1, name: "LCD", uniqueId: "00000000-0000-0000-0000-000000000001", primary: true,
                active: nil, backlightState: "off", currentOrientation: "rot0",
                nativeSize: SimulatorDisplay.Size(width: 1398, height: 2034), pointScale: 3
            ),
            SimulatorDisplay(
                displayId: 3, name: "LCD-1", uniqueId: "00000000-0000-0000-0000-000000000003", primary: false,
                active: nil, backlightState: "off", currentOrientation: "rot90",
                nativeSize: SimulatorDisplay.Size(width: 2007, height: 2853), pointScale: 3
            ),
        ])

        do {
            _ = try TouchTarget.resolve(state: state)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription == TouchTarget.unknownDisplayMessage)
        }
    }

    @Test("A non-main display without orientation or size throws")
    func missingGeometryThrows() {
        let state = SimulatorDisplayState(displays: [
            SimulatorDisplay(
                displayId: 1, name: "LCD", uniqueId: "00000000-0000-0000-0000-000000000001", primary: true,
                active: false, backlightState: "off", currentOrientation: "rot0",
                nativeSize: SimulatorDisplay.Size(width: 1398, height: 2034), pointScale: 3
            ),
            SimulatorDisplay(
                displayId: 3, name: "LCD-1", uniqueId: "00000000-0000-0000-0000-000000000003", primary: false,
                active: true, backlightState: "activeOn", currentOrientation: nil,
                nativeSize: SimulatorDisplay.Size(width: 2007, height: 2853), pointScale: 3
            ),
        ])

        #expect(throws: CLIError.self) { try TouchTarget.resolve(state: state) }
    }

    @Test(
        "Interface points convert to native points for every rotation",
        arguments: [
            (SimulatorDisplay.Rotation.rot0, 100.0, 200.0, 100.0, 200.0),
            (.rot90, 765.0, 380.0, 380.0, 186.0),
            (.rot180, 100.0, 200.0, 569.0, 751.0),
            (.rot270, 100.0, 200.0, 469.0, 100.0),
        ]
    )
    func interfaceToNative(
        rotation: SimulatorDisplay.Rotation,
        x: Double, y: Double,
        expectedX: Double, expectedY: Double
    ) {
        let target = innerTarget(rotation)
        let native = target.nativePoint(fromInterface: (x: x, y: y))

        expectClose(native.x, expectedX)
        expectClose(native.y, expectedY)

        let back = target.interfacePoint(fromNative: native)
        expectClose(back.x, x)
        expectClose(back.y, y)
    }

    @Test("The spike's Settings point normalises to the measured DTUHID ratio")
    func spikeRatio() {
        // backboardd reported the hit point rounded to whole pixels (185.67 pt = 557 px), so the
        // ratio and the point agree to half a pixel.
        let ratio = innerTarget(.rot90).normalized(nativePoint: (x: 380.33, y: 185.67))

        expectClose(ratio.x, 0.5685, tolerance: 0.0005)
        expectClose(ratio.y, 0.1954, tolerance: 0.0005)
    }

    @Test("Native AX rects convert to interface rects (Phase 0 Settings icon, rot90)")
    func nativeRectToInterface() {
        let rect = innerTarget(.rot90).interfaceRect(
            fromNative: AccessibilityElement.Frame(x: 346, y: 550.33, width: 86.67, height: 68)
        )

        expectClose(rect.x, 332.67)
        expectClose(rect.y, 346)
        expectClose(rect.width, 68)
        expectClose(rect.height, 86.67)
    }

    @Test("The display mapping converts interface points to native points")
    @MainActor
    func displayMappingConverts() throws {
        let point = try OrientationAwareCoordinates.applyMapping(
            .display(innerTarget(.rot90)), to: (x: 765, y: 380), logger: AxeLogger()
        )

        expectClose(point.x, 380)
        expectClose(point.y, 186)
    }

    @Test("A point outside the panel is refused with the point, the panel size and the display")
    @MainActor
    func pointOutsidePanelThrows() {
        do {
            // rot180 interface x = 810 is past the 669-point panel (an off-screen home page icon).
            _ = try OrientationAwareCoordinates.applyMapping(
                .display(innerTarget(.rot180)), to: (x: 810, y: 400), logger: AxeLogger()
            )
            Issue.record("Expected an error")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("(810.0, 400.0)"))
            #expect(message.contains("display 3"))
            #expect(message.contains("669.0x951.0"))
            #expect(message.contains("No touch was sent"))
        }
    }

    @Test("The main-display rotation mapping is unchanged")
    @MainActor
    func mainRotationUnchanged() throws {
        let point = try OrientationAwareCoordinates.applyMapping(
            .rotation(.landscape, portraitSize: (width: 390, height: 844)), to: (x: 100, y: 50), logger: AxeLogger()
        )

        #expect(point.x == 50 && point.y == 744)
    }
}

@Suite("Active panel accessibility windows")
struct ActivePanelWindowTests {
    // SpringBoard on the unfolded Duo (Phase 0 and review dumps, every rotation): one application
    // element sized like the cover (466x678) holding inner windows (669x951) and a smaller Dock
    // window, all with NATIVE frames, cover windows (466x678, same icon list) and pixel-sized
    // windows (2007x2853).
    private let springBoard = """
        [{
          "type": "Application",
          "frame": { "x": 0, "y": 0, "width": 466, "height": 678 },
          "children": [
            { "type": "Group", "frame": { "x": 0, "y": 0, "width": 669, "height": 951 },
              "children": [
                { "type": "Button", "AXLabel": "Settings", "AXUniqueId": "com.apple.Preferences",
                  "frame": { "x": 346, "y": 550.33, "width": 86.67, "height": 68 } }
              ] },
            { "type": "Group", "frame": { "x": 0, "y": 0, "width": 669, "height": 122 },
              "children": [
                { "type": "Button", "AXLabel": "Safari",
                  "frame": { "x": 315.67, "y": 15.83, "width": 64, "height": 64 } }
              ] },
            { "type": "Group", "frame": { "x": 0, "y": 0, "width": 466, "height": 678 },
              "children": [
                { "type": "Button", "AXLabel": "Settings", "AXUniqueId": "com.apple.Preferences",
                  "frame": { "x": 346, "y": 550.33, "width": 86.67, "height": 68 } },
                { "type": "Button", "AXLabel": "Safari",
                  "frame": { "x": 386.17, "y": 320, "width": 64, "height": 64 } }
              ] },
            { "type": "Group", "frame": { "x": 0, "y": 0, "width": 2007, "height": 2853 } }
          ]
        }]
        """

    // An app on the inner panel: the application element has the native size (669x951) and its
    // windows carry INTERFACE frames. Measured in Settings at rot90 (window 951x669) and rot180
    // (window 669x951, General row in a 250-point sidebar).
    private func app(windowWidth: Double, windowHeight: Double, extraWindow: String = "") -> String {
        """
        [{
          "type": "Application",
          "frame": { "x": 0, "y": 0, "width": 669, "height": 951 },
          "children": [
            { "type": "Group", "frame": { "x": 0, "y": 0, "width": \(windowWidth), "height": \(windowHeight) },
              "children": [
                { "type": "Button", "AXLabel": "General",
                  "frame": { "x": 20, "y": 253, "width": 210, "height": 52 } }
              ] }\(extraWindow)
          ]
        }]
        """
    }

    @Test("Without the filter, a home-screen label matches twice")
    func unfilteredDoubleMatch() throws {
        let roots = try decodeElements(springBoard)

        #expect(throws: ElementResolutionError.self) {
            try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Settings"))
        }
    }

    @Test(
        "SpringBoard's native frames resolve to the on-screen point in every rotation",
        arguments: [
            (SimulatorDisplay.Rotation.rot0, 389.33, 584.33),
            (.rot90, 366.67, 389.33),
            (.rot180, 279.67, 366.67),
            (.rot270, 584.33, 279.67),
        ]
    )
    func springBoardEveryRotation(rotation: SimulatorDisplay.Rotation, expectedX: Double, expectedY: Double) throws {
        let target = innerTarget(rotation)
        let roots = try decodeElements(springBoard)

        let resolution = try AccessibilityTargetResolver.resolveTap(
            roots: roots, query: .label("Settings"), target: target
        )
        expectClose(resolution.point.x, expectedX)
        expectClose(resolution.point.y, expectedY)

        // Converting back gives the icon's native centre whatever the rotation.
        let native = target.nativePoint(fromInterface: resolution.point)
        expectClose(native.x, 389.33)
        expectClose(native.y, 584.33)
    }

    @Test("Smaller SpringBoard windows (the Dock) are converted too")
    func springBoardDockConverted() throws {
        let resolution = try AccessibilityTargetResolver.resolveTap(
            roots: try decodeElements(springBoard), query: .label("Safari"), target: innerTarget(.rot90)
        )

        // Phase 0 measured the inner Dock Safari icon at about (903, 347) on screen.
        expectClose(resolution.point.x, 903.17)
        expectClose(resolution.point.y, 347.67)
    }

    @Test("Only the inner panel's windows are kept")
    func dropsForeignWindows() throws {
        let panel = try innerTarget(.rot90).activePanelRoots(decodeElements(springBoard))
        let windows = try #require(panel.first?.children)

        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.frame?.height != 678 && $0.frame?.width != 2007 })
    }

    @Test(
        "App windows keep their interface frames in every rotation, including rot180",
        arguments: [
            (SimulatorDisplay.Rotation.rot90, 951.0, 669.0),
            (.rot180, 669.0, 951.0),
            (.rot270, 951.0, 669.0),
            (.rot0, 669.0, 951.0),
        ]
    )
    func appWindowsUnchanged(rotation: SimulatorDisplay.Rotation, width: Double, height: Double) throws {
        let roots = try decodeElements(app(windowWidth: width, windowHeight: height))

        let resolution = try AccessibilityTargetResolver.resolveTap(
            roots: roots, query: .label("General"), target: innerTarget(rotation)
        )

        expectClose(resolution.point.x, 125)
        expectClose(resolution.point.y, 279)
    }

    @Test("Keyboard and alert windows inside an app are kept")
    func keepsKeyboardAndAlertWindows() throws {
        let keyboard = """
            ,
            { "type": "Group", "frame": { "x": 0, "y": 369, "width": 951, "height": 300 },
              "children": [
                { "type": "Button", "AXLabel": "return",
                  "frame": { "x": 850, "y": 600, "width": 90, "height": 50 } }
              ] },
            { "type": "Group", "frame": { "x": 300, "y": 200, "width": 350, "height": 200 },
              "children": [
                { "type": "Button", "AXLabel": "Allow",
                  "frame": { "x": 480, "y": 340, "width": 150, "height": 44 } }
              ] }
            """
        let roots = try decodeElements(app(windowWidth: 951, windowHeight: 669, extraWindow: keyboard))
        let target = innerTarget(.rot90)

        let key = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("return"), target: target)
        expectClose(key.point.x, 895)
        expectClose(key.point.y, 625)

        let allow = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Allow"), target: target)
        expectClose(allow.point.x, 555)
        expectClose(allow.point.y, 362)
    }

    @Test("A main-display target leaves the tree unchanged")
    func mainTargetDoesNotFilter() throws {
        let main = TouchTarget(
            displayID: 1,
            nativePixelSize: SimulatorDisplay.Size(width: 1398, height: 2034),
            pointScale: 3,
            rotation: .rot0,
            isMain: true,
            foreignWindowSizes: [SimulatorDisplay.Size(width: 669, height: 951)]
        )
        let roots = try decodeElements(springBoard)

        #expect(try main.activePanelRoots(roots).first?.children?.count == 4)
    }

    @Test("A tree with no window on the active panel fails instead of using the other panel's windows")
    func noPanelWindowThrows() throws {
        let roots = try decodeElements("""
            [{ "type": "Application", "frame": { "x": 0, "y": 0, "width": 466, "height": 678 },
               "children": [
                 { "type": "Group", "frame": { "x": 0, "y": 0, "width": 466, "height": 678 },
                   "children": [ { "type": "Button", "AXLabel": "Settings",
                                   "frame": { "x": 346, "y": 550.33, "width": 86.67, "height": 68 } } ] }
               ] }]
            """)

        do {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Settings"), target: innerTarget(.rot90))
            Issue.record("Expected an error")
        } catch {
            #expect(error is CLIError)
            #expect(error.localizedDescription.contains("no window on display 3"))
        }
    }

    @Test("Foreign window sizes come from the other displays and the pixel sizes")
    func foreignSizesFromState() throws {
        let target = try #require(try TouchTarget.resolve(state: fixtureState("duo-unfolded")))

        #expect(target.foreignWindowSizes.contains(SimulatorDisplay.Size(width: 466, height: 678)))
        #expect(target.foreignWindowSizes.contains(SimulatorDisplay.Size(width: 2007, height: 2853)))
        #expect(!target.foreignWindowSizes.contains(SimulatorDisplay.Size(width: 669, height: 951)))
    }
}

@Suite("Touch routing decision")
struct TouchRoutingTests {
    @Test("DTUHID with a non-main target routes to that display")
    func dtuhidRoutes() async throws {
        let state = try fixtureState("duo-unfolded")
        let hid = try await TouchRouting.hidTarget(transport: .dtuhid) { state }

        #expect(hid?.displayID == 3)
    }

    @Test("Indigo cannot reach a non-main display")
    func indigoFails() async throws {
        let state = try fixtureState("duo-unfolded")

        do {
            _ = try await TouchRouting.hidTarget(transport: .indigo) { state }
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription == TouchRouting.indigoTransportMessage(displayID: 3))
        }
    }

    @Test("A devicectl failure is an error")
    func devicectlFailure() async {
        await #expect(throws: CLIError.self) {
            try await TouchRouting.hidTarget(transport: .dtuhid) {
                throw CLIError(errorDescription: "devicectl failed")
            }
        }
    }

    @Test(
        "Without a non-main display the old behaviour applies on either transport",
        arguments: [FBSimulatorHIDTransportType.dtuhid, .indigo]
    )
    func mainOrUnprobed(transport: FBSimulatorHIDTransportType) async throws {
        // AXE_DISPLAY_PROBE=never and non-foldables give no state.
        #expect(try await TouchRouting.hidTarget(transport: transport) { nil } == nil)
        let folded = try fixtureState("duo-folded")
        #expect(try await TouchRouting.hidTarget(transport: transport) { folded } == nil)
        let single = try fixtureState("single-display")
        #expect(try await TouchRouting.hidTarget(transport: transport) { single } == nil)
    }

    @Test("The disabled-probe warning names the override and the cover")
    func probeDisabledWarning() {
        #expect(TouchRouting.probeDisabledWarning.contains("AXE_DISPLAY_PROBE=never"))
        #expect(TouchRouting.probeDisabledWarning.contains("cover display"))
    }

    @Test("Only touch events are routed")
    func classifiesTouchEvents() {
        #expect(FBSimulatorHIDEvent.tapAt(x: 1, y: 2).producesTouch)
        #expect(FBSimulatorHIDEvent.touch(direction: .down, x: 1, y: 2).producesTouch)
        #expect(FBSimulatorHIDEvent.composite([.delay(0.1), .touch(direction: .up, x: 1, y: 2)]).producesTouch)
        #expect(FBSimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 10, yEnd: 10, delta: 5, duration: 0.1).producesTouch)
        #expect(!FBSimulatorHIDEvent.shortKeyPress(4).producesTouch)
        #expect(!FBSimulatorHIDEvent.shortButtonPress(.homeButton).producesTouch)
        #expect(!FBSimulatorHIDEvent.composite([.delay(0.1), .keyboard(direction: .down, keyCode: 4)]).producesTouch)
    }

    @Test("Routing messages survive localizedDescription")
    func messageSurvivesLocalizedDescription() {
        let error: Error = CLIError(errorDescription: TouchTarget.unknownDisplayMessage)

        #expect(error.localizedDescription == TouchTarget.unknownDisplayMessage)
    }
}

@Suite("Gesture and slider on the inner display")
struct InnerDisplayCommandTests {
    @Test("Without a target the preset coordinates are unchanged")
    func mainDisplayUnchanged() throws {
        let gesture = try Gesture.parse(["scroll-down", "--udid", "SIMULATOR_UDID"])
        let coords = try gesture.coordinates(target: nil)

        #expect(gesture.screenSize(target: nil) == (width: 390, height: 844))
        #expect(coords == (195, 322, 195, 522))
    }

    @Test("On the inner display presets use its interface size and native coordinates")
    func innerDisplayConverted() throws {
        let gesture = try Gesture.parse(["scroll-down", "--udid", "SIMULATOR_UDID"])
        let target = innerTarget(.rot90)
        let coords = try gesture.coordinates(target: target)

        #expect(gesture.screenSize(target: target) == (width: 951, height: 669))
        // Interface (475.5, 234.5) → (475.5, 434.5); native = (y, 951 - x).
        expectClose(coords.startX, 234.5)
        expectClose(coords.startY, 475.5)
        expectClose(coords.endX, 434.5)
        expectClose(coords.endY, 475.5)
    }

    @Test("A preset outside the inner display is refused")
    func presetOutsidePanelThrows() throws {
        let gesture = try Gesture.parse(["swipe-from-right-edge", "--screen-width", "1500", "--udid", "SIMULATOR_UDID"])

        #expect(throws: CLIError.self) { try gesture.coordinates(target: innerTarget(.rot90)) }
    }

    @Test("A slider drag on the inner display is clamped to the display, not the AX application frame")
    func sliderClampsToDisplay() {
        // SpringBoard-style application frame (the cover's size) must not limit the drag.
        let applicationFrame = AccessibilityElement.Frame(x: 0, y: 0, width: 466, height: 678)
        let frame = Slider.dragClampFrame(applicationFrame: applicationFrame, touchTarget: innerTarget(.rot90))

        #expect(Slider.clampedDragEndX(800, applicationFrame: frame) == 800)
        #expect(Slider.clampedDragEndX(1200, applicationFrame: frame) == 951)
        #expect(Slider.dragClampFrame(applicationFrame: applicationFrame, touchTarget: nil)?.width == 466)
    }
}
