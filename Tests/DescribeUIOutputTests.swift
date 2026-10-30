import Foundation
import Testing
@testable import AXe

// Fixtures in Fixtures/describe-ui follow the measured iPhone Duo shapes (Xcode 27.2):
// - springboard-unfolded: SpringBoard with the inner display active. The application element is
//   cover-sized (466x678); inner windows (669x951 and the 669x122 Dock) carry NATIVE portrait
//   frames whatever the rotation; a cover window repeats the Settings icon; two pixel-sized
//   backing windows. Fitness has the all-zero "no frame" frame.
// - settings-rot90: Settings on the inner display at rot90. The application element is
//   native-shaped (669x951) and its windows carry INTERFACE frames (951x669).

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/describe-ui")
    )
    return try Data(contentsOf: url)
}

private func displayState(_ name: String) throws -> SimulatorDisplayState {
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

private func roots(_ data: Data) throws -> [DescribedElement] {
    let object = try JSONSerialization.jsonObject(with: data)
    let array = try #require(object as? [[String: Any]])
    return array.map(DescribedElement.init(json:))
}

private func flattened(_ element: DescribedElement) -> [DescribedElement] {
    [element] + (element.children ?? []).flatMap(flattened)
}

private func elements(labelled label: String, in roots: [DescribedElement]) -> [DescribedElement] {
    roots.flatMap(flattened).filter { $0.json["AXLabel"] as? String == label }
}

private func expectFrame(
    _ element: DescribedElement?,
    _ x: Double, _ y: Double, _ width: Double, _ height: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let frame = element?.frame else {
        Issue.record("Missing frame", sourceLocation: sourceLocation)
        return
    }
    let close = abs(frame.x - x) < 0.01 && abs(frame.y - y) < 0.01
        && abs(frame.width - width) < 0.01 && abs(frame.height - height) < 0.01
    #expect(close, "\(frame) != {{\(x), \(y)}, {\(width), \(height)}}", sourceLocation: sourceLocation)
    // AXFrame always mirrors frame.
    if let element {
        #expect(element.json["AXFrame"] as? String == DescribedElement.axFrameString(frame), sourceLocation: sourceLocation)
    }
}

@Suite("describe-ui output on the active display")
struct DescribeUIOutputTests {
    // MARK: Unchanged paths

    @Test(
        "Without a non-main target the simulator's JSON is returned byte for byte",
        arguments: ["springboard-unfolded", "settings-rot90"]
    )
    func identityWithoutTarget(fixture: String) throws {
        let data = try fixtureData(fixture)
        #expect(try DescribeUIOutput.panelTreeData(data, target: nil) == data)

        let cover = TouchTarget(
            displayID: 1,
            nativePixelSize: SimulatorDisplay.Size(width: 1398, height: 2034),
            pointScale: 3,
            rotation: .rot0,
            isMain: true,
            foreignWindowSizes: [SimulatorDisplay.Size(width: 669, height: 951)]
        )
        #expect(try DescribeUIOutput.panelTreeData(data, target: cover) == data)
    }

    @Test("The element model keeps every key and value of the schema")
    func modelRoundTrip() throws {
        let data = try fixtureData("springboard-unfolded")
        let original = try JSONSerialization.jsonObject(with: data)
        let rebuilt = try roots(data).map { root in
            root.replacingChildren(root.children ?? []).mappingFrames { $0 }
        }

        #expect((original as? NSArray)?.isEqual(to: rebuilt.map(\.json)) == true)
    }

    @Test(
        "AXFrame uses the simulator's number format",
        arguments: [
            "{{170, 73.833333333333329}, {62, 20.333333333333329}}",
            "{{-8, -1792.6666666666667}, {418, 2022}}",
            "{{729.66666666666674, 346}, {68, 86.666666666666686}}",
            "{{0, 0}, {951, 669}}",
        ]
    )
    func axFrameFormat(string: String) throws {
        let numbers = string
            .components(separatedBy: CharacterSet(charactersIn: "{}, "))
            .filter { !$0.isEmpty }
            .compactMap(Double.init)
        try #require(numbers.count == 4)
        let frame = AccessibilityElement.Frame(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])

        #expect(DescribedElement.axFrameString(frame) == string)
    }

    @Test("--all-displays skips the display probe and keeps every window")
    func allDisplaysKeepsEverything() async throws {
        let unfolded = try displayState("duo-unfolded")
        var probed = false
        let target = await DescribeUIOutput.displayTarget(allDisplays: true) {
            probed = true
            return unfolded
        }
        #expect(target == nil)
        #expect(!probed)

        let data = try fixtureData("springboard-unfolded")
        let output = try DescribeUIOutput.panelTreeData(data, target: target)
        #expect(output == data)
        #expect(try roots(output).first?.children?.count == 5)
        #expect(elements(labelled: "Settings", in: try roots(output)).count == 2)
    }

    @Test("The display target is the inner display when it is active, nil otherwise")
    func displayTargetFromState() async throws {
        let unfolded = try displayState("duo-unfolded")
        let folded = try displayState("duo-folded")
        let single = try displayState("single-display")
        var warnings: [String] = []
        let warn: (String) -> Void = { warnings.append($0) }

        #expect(await DescribeUIOutput.displayTarget(allDisplays: false, warn: warn) { unfolded }?.displayID == 3)
        #expect(await DescribeUIOutput.displayTarget(allDisplays: false, warn: warn) { folded } == nil)
        #expect(await DescribeUIOutput.displayTarget(allDisplays: false, warn: warn) { single } == nil)
        #expect(await DescribeUIOutput.displayTarget(allDisplays: false, warn: warn) { nil } == nil)
        #expect(warnings.isEmpty)
    }

    @Test("A devicectl failure falls back to the unfiltered tree with one warning")
    func displayDetectionFailureFallsBack() async throws {
        var warnings: [String] = []
        let target = await DescribeUIOutput.displayTarget(allDisplays: false, warn: { warnings.append($0) }) {
            throw CLIError(errorDescription: "devicectl timed out")
        }

        #expect(target == nil)
        #expect(warnings == [DescribeUIOutput.fallbackWarning(reason: "devicectl timed out")])
        #expect(warnings.first?.hasPrefix("Warning: could not determine the active display (devicectl timed out)") == true)
        #expect(warnings.first?.hasSuffix("; showing all displays unfiltered.") == true)
        let data = try fixtureData("springboard-unfolded")
        #expect(try DescribeUIOutput.panelTreeData(data, target: target) == data)
    }

    @Test("An undeterminable active display or missing geometry falls back with one warning")
    func unknownActiveDisplayFallsBack() async throws {
        let cover = SimulatorDisplay(
            displayId: 1, name: "LCD", uniqueId: "00000000-0000-0000-0000-000000000001", primary: true,
            active: nil, backlightState: "off", currentOrientation: "rot0",
            nativeSize: SimulatorDisplay.Size(width: 1398, height: 2034), pointScale: 3
        )
        let unknown = SimulatorDisplayState(displays: [
            cover,
            SimulatorDisplay(
                displayId: 3, name: "LCD-1", uniqueId: "00000000-0000-0000-0000-000000000003", primary: false,
                active: nil, backlightState: "off", currentOrientation: "rot90",
                nativeSize: SimulatorDisplay.Size(width: 2007, height: 2853), pointScale: 3
            ),
        ])
        let noGeometry = SimulatorDisplayState(displays: [
            cover,
            SimulatorDisplay(
                displayId: 3, name: "LCD-1", uniqueId: "00000000-0000-0000-0000-000000000003", primary: false,
                active: true, backlightState: "activeOn", currentOrientation: nil,
                nativeSize: SimulatorDisplay.Size(width: 2007, height: 2853), pointScale: 3
            ),
        ])
        var warnings: [String] = []

        #expect(await DescribeUIOutput.displayTarget(allDisplays: false, warn: { warnings.append($0) }) { unknown } == nil)
        #expect(await DescribeUIOutput.displayTarget(allDisplays: false, warn: { warnings.append($0) }) { noGeometry } == nil)
        #expect(warnings.count == 2)
        #expect(warnings.first == DescribeUIOutput.fallbackWarning(reason: "devicectl reports no active display"))
        #expect(warnings.last?.contains("did not report its orientation and size") == true)
        #expect(warnings.allSatisfy { !$0.contains("touch") })
        #expect(warnings.allSatisfy { $0.hasSuffix("showing all displays unfiltered.") })
    }

    // MARK: Filtering and conversion

    @Test("SpringBoard at rot90: only the inner windows, in interface points")
    func springBoardRot90() throws {
        let output = try roots(DescribeUIOutput.panelTreeData(fixtureData("springboard-unfolded"), target: innerTarget(.rot90)))
        let root = try #require(output.first)

        #expect(output.count == 1)
        expectFrame(root, 0, 0, 951, 669)
        let windows = try #require(root.children)
        #expect(windows.count == 2)
        expectFrame(windows[0], 0, 0, 951, 669)
        // Dock: native {{0, 0}, {669, 122}} → the right edge in landscape.
        expectFrame(windows[1], 829, 0, 122, 669)

        let settings = elements(labelled: "Settings", in: output)
        #expect(settings.count == 1)
        // Measured on the live Duo: interface centre (763.7, 389.3).
        expectFrame(settings.first, 729.67, 346, 68, 86.67)
        expectFrame(settings.first?.children?.first, 734, 348, 60, 74)
        expectFrame(elements(labelled: "Safari", in: output).first, 871.17, 315.67, 64, 64)
        // The all-zero "no frame" frame is not moved to a panel corner.
        expectFrame(elements(labelled: "Fitness", in: output).first, 0, 0, 0, 0)
    }

    @Test("SpringBoard at rot180: native frames turned half a turn")
    func springBoardRot180() throws {
        let output = try roots(DescribeUIOutput.panelTreeData(fixtureData("springboard-unfolded"), target: innerTarget(.rot180)))

        expectFrame(output.first, 0, 0, 669, 951)
        expectFrame(output.first?.children?[1], 0, 829, 669, 122)
        let settings = elements(labelled: "Settings", in: output)
        #expect(settings.count == 1)
        expectFrame(settings.first, 236.33, 729.67, 86.67, 68)
    }

    @Test("SpringBoard at rot270: native frames turned a quarter the other way")
    func springBoardRot270() throws {
        let output = try roots(DescribeUIOutput.panelTreeData(fixtureData("springboard-unfolded"), target: innerTarget(.rot270)))

        expectFrame(output.first, 0, 0, 951, 669)
        // Dock: native {{0, 0}, {669, 122}} → the left edge in landscape-flipped.
        expectFrame(output.first?.children?[1], 0, 0, 122, 669)
        let settings = elements(labelled: "Settings", in: output)
        #expect(settings.count == 1)
        // rot270: interface (x, y) = (native y, 669 - native x).
        expectFrame(settings.first, 153.33, 236.33, 68, 86.67)
    }

    @Test("Converted elements keep the full schema")
    func convertedKeepsSchema() throws {
        let data = try fixtureData("springboard-unfolded")
        let before = try #require(elements(labelled: "Settings", in: roots(data)).first)
        let output = try roots(DescribeUIOutput.panelTreeData(data, target: innerTarget(.rot90)))
        let after = try #require(elements(labelled: "Settings", in: output).first)

        #expect(Set(before.json.keys) == Set(after.json.keys))
        #expect((after.json["custom_actions"] as? [String]) == ["Edit mode"])
        #expect(after.json["pid"] as? Int == 1000)
        #expect(after.json["subrole"] is NSNull)
    }

    @Test("An app at rot90 keeps its interface frames; only the native-shaped root frame is turned")
    func settingsAppRot90() throws {
        let data = try fixtureData("settings-rot90")
        let output = try roots(DescribeUIOutput.panelTreeData(data, target: innerTarget(.rot90)))
        let root = try #require(output.first)

        expectFrame(root, 0, 0, 951, 669)
        #expect(root.children?.count == 2)
        let general = try #require(elements(labelled: "General", in: output).first { $0.json["type"] as? String == "Button" })
        expectFrame(general, 20, 192.33, 280, 52)
        // Untouched frames keep the simulator's exact AXFrame string.
        #expect(general.json["AXFrame"] as? String == "{{20, 192.33333333333334}, {280, 52}}")
    }

    @Test("A tree with no window on the active display fails and points to --all-displays")
    func noPanelWindowThrows() throws {
        let data = Data("""
            [{ "type": "Application", "frame": { "x": 0, "y": 0, "width": 466, "height": 678 },
               "children": [ { "type": "Group", "frame": { "x": 0, "y": 0, "width": 466, "height": 678 } } ] }]
            """.utf8)

        do {
            _ = try DescribeUIOutput.panelTreeData(data, target: innerTarget(.rot90))
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("no window on display 3"))
            #expect(error.localizedDescription.contains("--all-displays"))
            #expect(!error.localizedDescription.contains("No touch was sent"))
        }
    }

    // MARK: Hit-testing

    private func hit(
        _ fixture: String,
        _ rotation: SimulatorDisplay.Rotation,
        _ x: Double,
        _ y: Double
    ) throws -> [String: Any] {
        let output = try DescribeUIOutput.elementData(
            at: AccessibilityPoint(x: x, y: y),
            in: fixtureData(fixture),
            target: innerTarget(rotation)
        )
        // Same shape as the simulator's hit test: one element object, not an array.
        return try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    @Test("--point on the Settings icon returns the icon, not its unlabelled image group")
    func hitSettingsIcon() throws {
        let rot90 = try hit("springboard-unfolded", .rot90, 763.67, 389.33)
        #expect(rot90["AXUniqueId"] as? String == "Settings")
        #expect(rot90["type"] as? String == "Button")
        #expect(rot90["AXFrame"] as? String == DescribedElement.axFrameString(DescribedElement(json: rot90).frame!))
        #expect((rot90["children"] as? [Any])?.count == 2)

        let inImage = try hit("springboard-unfolded", .rot90, 764, 385)
        #expect(inImage["AXUniqueId"] as? String == "Settings")

        let rot180 = try hit("springboard-unfolded", .rot180, 279.67, 763.67)
        #expect(rot180["AXUniqueId"] as? String == "Settings")
    }

    @Test("--point on the icon caption returns the icon, not its identifier-only label-view")
    func hitSettingsCaption() throws {
        // Live finding: (753, 420) on the "Settings" caption returned Group id=label-view.
        // label-view is {{731.67, 411}, {64, 19.67}} in interface points.
        let caption = try hit("springboard-unfolded", .rot90, 763, 425)

        #expect(caption["type"] as? String == "Button")
        #expect(caption["AXLabel"] as? String == "Settings")
    }

    @Test("An identifier-only element without a labelled ancestor is still returned")
    func hitIdentifierOnly() throws {
        // The header group (id "General", no label) at a point away from its heading.
        let header = try hit("settings-rot90", .rot90, 300, 50)

        #expect(header["AXUniqueId"] as? String == "General")
        #expect(header["type"] as? String == "Group")
    }

    @Test("A later (front) window wins over a deeper element in an earlier window")
    func hitFrontWindowFirst() throws {
        // The OK button (depth 2, front window) covers the Settings icon (depth 4, home window).
        let front = try hit("springboard-overlay", .rot90, 763.67, 389.33)
        #expect(front["AXLabel"] as? String == "OK")

        // Where the front window has nothing described, the search falls through to the home window.
        let behind = try hit("springboard-overlay", .rot90, 217, 93)
        #expect(behind["AXLabel"] as? String == "Files")
    }

    // An app-shaped tree (root and window already in interface points) for ranking tests.
    private func hitInline(_ elements: String, _ x: Double, _ y: Double) throws -> [String: Any] {
        let data = Data("""
            [{ "type": "Application", "AXLabel": "App", "frame": { "x": 0, "y": 0, "width": 951, "height": 669 },
               "children": [ { "type": "Group", "frame": { "x": 0, "y": 0, "width": 951, "height": 669 },
                               "children": [ \(elements) ] } ] }]
            """.utf8)
        let output = try DescribeUIOutput.elementData(
            at: AccessibilityPoint(x: x, y: y), in: data, target: innerTarget(.rot90)
        )
        return try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    @Test("At the same depth the smaller frame wins, then the later element")
    func hitTieBreaks() throws {
        let nested = """
            { "type": "Button", "AXLabel": "Big", "frame": { "x": 0, "y": 0, "width": 200, "height": 200 } },
            { "type": "Button", "AXLabel": "Small", "frame": { "x": 50, "y": 50, "width": 20, "height": 20 } }
            """
        #expect(try hitInline(nested, 60, 60)["AXLabel"] as? String == "Small")

        let sameFrame = """
            { "type": "Button", "AXLabel": "First", "frame": { "x": 0, "y": 0, "width": 100, "height": 100 } },
            { "type": "Button", "AXLabel": "Second", "frame": { "x": 0, "y": 0, "width": 100, "height": 100 } }
            """
        #expect(try hitInline(sameFrame, 10, 10)["AXLabel"] as? String == "Second")
    }

    @Test("A zero-sized element at the point never wins")
    func hitIgnoresZeroSize() throws {
        let elements = """
            { "type": "Button", "AXLabel": "Row", "frame": { "x": 0, "y": 0, "width": 300, "height": 100 },
              "children": [ { "type": "Button", "AXLabel": "Zero", "frame": { "x": 60, "y": 60, "width": 0, "height": 0 } },
                            { "type": "Button", "AXLabel": "Line", "frame": { "x": 60, "y": 60, "width": 0, "height": 40 } } ] }
            """
        #expect(try hitInline(elements, 60, 60)["AXLabel"] as? String == "Row")
    }

    @Test("An empty AXValue or a blank label does not describe an element")
    func hitIgnoresEmptyText() throws {
        let elements = """
            { "type": "Button", "AXLabel": "Row", "frame": { "x": 0, "y": 0, "width": 300, "height": 100 },
              "children": [ { "type": "Group", "AXLabel": " ", "AXValue": "", "frame": { "x": 10, "y": 10, "width": 50, "height": 50 } } ] }
            """
        #expect(try hitInline(elements, 20, 20)["AXLabel"] as? String == "Row")
        #expect(!DescribedElement(json: ["AXLabel": " ", "AXValue": "", "AXUniqueId": NSNull()]).isDescribed)
        #expect(DescribedElement(json: ["AXValue": "50%"]).hasLabelOrValue)
    }

    @Test("Frames are half-open: a shared edge belongs to the lower row, a far edge to no element")
    func hitEdges() throws {
        let rows = """
            { "type": "Button", "AXLabel": "Row1", "frame": { "x": 0, "y": 100, "width": 300, "height": 50 } },
            { "type": "Button", "AXLabel": "Row2", "frame": { "x": 0, "y": 150, "width": 300, "height": 50 } }
            """
        #expect(try hitInline(rows, 10, 150)["AXLabel"] as? String == "Row2")
        #expect(try hitInline(rows, 10, 149.9)["AXLabel"] as? String == "Row1")
        // x = 300 is past Row1's right edge: the window (a container) is returned instead.
        #expect(try hitInline(rows, 300, 120)["type"] as? String == "Group")

        // The display bounds are inclusive like touch coordinates, but no frame contains its far corner.
        do {
            _ = try hitInline(rows, 951, 669)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("No accessibility element contains point (951.0, 669.0)"))
        }
    }

    @Test("--point on the Dock returns Safari")
    func hitDock() throws {
        #expect(try hit("springboard-unfolded", .rot90, 903.17, 347.67)["AXLabel"] as? String == "Safari")
    }

    @Test("--point on an empty area returns the deepest container")
    func hitEmptyArea() throws {
        let element = try hit("springboard-unfolded", .rot90, 100, 600)

        #expect(element["type"] as? String == "Group")
        expectFrame(DescribedElement(json: element), 0, 0, 951, 669)
        #expect(element["AXLabel"] is NSNull)
    }

    @Test("--point inside an app returns the row, or its text when the point is on the text")
    func hitSettingsRows() throws {
        let row = try hit("settings-rot90", .rot90, 160, 218.33)
        #expect(row["AXUniqueId"] as? String == "com.apple.settings.general")
        #expect(row["type"] as? String == "Button")
        #expect((row["children"] as? [Any])?.count == 2)

        // The simulator's own hit test also returns the StaticText over a row's text.
        let text = try hit("settings-rot90", .rot90, 100, 218.33)
        #expect(text["type"] as? String == "StaticText")
        #expect(text["AXLabel"] as? String == "General")

        let heading = try hit("settings-rot90", .rot90, 603, 48)
        #expect(heading["type"] as? String == "Heading")
    }

    @Test("--point outside the display is refused with the display size")
    func hitOutsideDisplay() throws {
        do {
            _ = try hit("springboard-unfolded", .rot90, 1000, 100)
            Issue.record("Expected an error")
        } catch {
            #expect(error is CLIError)
            #expect(error.localizedDescription.contains("(1000.0, 100.0)"))
            #expect(error.localizedDescription.contains("outside display 3"))
            #expect(error.localizedDescription.contains("951.0x669.0"))
        }
    }
}
