import ArgumentParser
import Foundation
import Testing
@testable import AXe

private func devicectlFixture(_ name: String) throws -> SimulatorDisplayState {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/devicectl")
    )
    return try SimulatorDisplayState.decode(from: Data(contentsOf: url))
}

private func jsonObject(_ data: Data) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func makeDisplay(id: Int, primary: Bool, active: Bool?, rotation: String) -> SimulatorDisplay {
    SimulatorDisplay(
        displayId: id,
        name: primary ? "LCD" : "LCD-1",
        uniqueId: "00000000-0000-0000-0000-00000000000\(id)",
        primary: primary,
        active: active,
        backlightState: active == true ? "activeOn" : "off",
        currentOrientation: rotation,
        nativeSize: primary ? SimulatorDisplay.Size(width: 1398, height: 2034) : SimulatorDisplay.Size(width: 2007, height: 2853),
        pointScale: 3
    )
}

/// A foldable state with the given active panel and rotation of the active display.
private func duoState(active: FoldablePanel, rotation: String = "rot0", deviceOrientation: String? = "portrait") -> SimulatorDisplayState {
    SimulatorDisplayState(
        displays: [
            makeDisplay(id: 1, primary: true, active: active == .cover, rotation: active == .cover ? rotation : "rot0"),
            makeDisplay(id: 3, primary: false, active: active == .inner, rotation: active == .inner ? rotation : "rot90"),
        ],
        deviceOrientation: deviceOrientation
    )
}

private func singleState(rotation: String) -> SimulatorDisplayState {
    SimulatorDisplayState(displays: [makeDisplay(id: 1, primary: true, active: nil, rotation: rotation)])
}

/// Records the operations a hinge or rotation action performs, with a fake clock.
@MainActor
private final class FakeSimulator {
    var time = Date(timeIntervalSinceReferenceDate: 0)
    /// Angle readings in order; the last one repeats.
    var angleReadings: [HingeAngleReading] = [.angle(0)]
    var displayState: SimulatorDisplayState
    var helperCalls: [[String]] = []
    var deviceOrientationsSet: [String] = []
    var reportedDeviceOrientation: String?
    /// Called after each helper call; may change `displayState` or `angleReadings`.
    var onHelper: ([String]) -> Void = { _ in }
    /// Called after a devicectl orientation set.
    var onSetDeviceOrientation: (String) -> Void = { _ in }

    init(displayState: SimulatorDisplayState) {
        self.displayState = displayState
    }

    var driver: FoldableDriver {
        FoldableDriver(
            readAngle: { [unowned self] in
                let reading = angleReadings.first ?? .unreadable("none")
                if angleReadings.count > 1 {
                    angleReadings.removeFirst()
                }
                return reading
            },
            runHelper: { [unowned self] arguments, _ in
                helperCalls.append(arguments)
                onHelper(arguments)
            },
            readDisplays: { [unowned self] in displayState },
            setDeviceOrientation: { [unowned self] value in
                deviceOrientationsSet.append(value)
                onSetDeviceOrientation(value)
            },
            readDeviceOrientation: { [unowned self] in reportedDeviceOrientation },
            sleep: { [unowned self] seconds in time = time.addingTimeInterval(seconds) },
            now: { [unowned self] in time },
            log: { _ in }
        )
    }
}

@Suite("Hinge rules")
struct HingeRulesTests {
    @Test("Accepts angles from 0 to 180", arguments: [0.0, 0.5, 90, 130, 180])
    func acceptsValidAngles(degrees: Double) throws {
        try HingeRules.validate(degrees)
    }

    @Test("Rejects angles outside 0 to 180", arguments: [-1.0, 180.1, 200, .nan, .infinity])
    func rejectsInvalidAngles(degrees: Double) {
        #expect(throws: ValidationError.self) {
            try HingeRules.validate(degrees)
        }
    }

    @Test(
        "Expected panel: cover up to 30, inner from 120, none between",
        arguments: [
            (0.0, FoldablePanel?.some(.cover)),
            (30, .cover),
            (30.1, nil),
            (90, nil),
            (119.9, nil),
            (120, .inner),
            (180, .inner),
        ]
    )
    func expectedPanel(degrees: Double, expected: FoldablePanel?) {
        #expect(HingeRules.expectedPanel(for: degrees) == expected)
    }

    @Test("Sweep duration has a 0.4 s floor", arguments: [(0.0, 0.4), (0.1, 0.4), (0.4, 0.4), (1.5, 1.5)])
    func sweepDurationFloor(requested: Double, expected: Double) {
        #expect(HingeRules.sweepDuration(requested: requested) == expected)
    }

    @Test("Endpoints confirm within 0.5 degrees, intermediate angles within 5")
    func confirmationTolerance() {
        #expect(HingeRules.tolerance(for: 0) == 0.5)
        #expect(HingeRules.tolerance(for: 180) == 0.5)
        #expect(HingeRules.tolerance(for: 90) == 5)
        #expect(HingeRules.isConfirmed(reported: 0.4, target: 0))
        #expect(!HingeRules.isConfirmed(reported: 1, target: 0))
        #expect(HingeRules.isConfirmed(reported: 87.9, target: 90))
        #expect(HingeRules.isConfirmed(reported: 131, target: 135))
        #expect(!HingeRules.isConfirmed(reported: 120, target: 135))
    }
}

@Suite("Hinge sweep plan")
struct HingeSweepPlanTests {
    @Test("set sweeps from the current angle")
    func setFromCurrent() {
        let plan = HingeRules.sweepPlan(current: 180, start: nil, target: 0, duration: 0)

        #expect(plan == [HingeSweep(from: 180, to: 0, duration: 0.4)])
        #expect(plan[0].helperArguments == ["hinge-sweep", "180.0", "0.0", "0.400"])
    }

    @Test("An unreadable angle sweeps from the opposite endpoint, never a direct set", arguments: [(0.0, 180.0), (90, 0), (180, 0), (60, 180)])
    func unreadableUsesOppositeEndpoint(target: Double, assumedStart: Double) {
        let plan = HingeRules.sweepPlan(current: nil, start: nil, target: target, duration: 0)

        #expect(plan == [HingeSweep(from: assumedStart, to: target, duration: 0.4)])
    }

    @Test("sweep first moves to <from> when the hinge is elsewhere")
    func sweepMovesToStartFirst() {
        let plan = HingeRules.sweepPlan(current: 0, start: 180, target: 0, duration: 2)

        #expect(plan == [
            HingeSweep(from: 0, to: 180, duration: 0.4),
            HingeSweep(from: 180, to: 0, duration: 2),
        ])
    }

    @Test("sweep starts directly when the hinge is already at <from>")
    func sweepFromCurrentStart() {
        #expect(HingeRules.sweepPlan(current: 179.8, start: 180, target: 0, duration: 1) == [HingeSweep(from: 180, to: 0, duration: 1)])
        #expect(HingeRules.sweepPlan(current: 93, start: 90, target: 180, duration: 0) == [HingeSweep(from: 90, to: 180, duration: 0.4)])
    }

    @Test("sweep with an unreadable angle first sweeps from the opposite endpoint to <from>")
    func sweepUnreadable() {
        let plan = HingeRules.sweepPlan(current: nil, start: 180, target: 0, duration: 0)

        #expect(plan == [
            HingeSweep(from: 0, to: 180, duration: 0.4),
            HingeSweep(from: 180, to: 0, duration: 0.4),
        ])
    }
}

@Suite("Hinge move flow")
@MainActor
struct HingeMoveFlowTests {
    @Test("close: one sweep from the current angle, angle confirmed, cover awaited")
    func closeFromOpen() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.angle(180), .angle(0)]

        try await FoldableDevice.moveHinge(from: nil, to: 0, duration: 0, waitForDisplay: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(fake.helperCalls == [["hinge-sweep", "180.0", "0.0", "0.400"]])
    }

    @Test("sweep from a different angle moves to <from> first")
    func sweepFromElsewhere() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.angle(0), .angle(0)]

        try await FoldableDevice.moveHinge(from: 180, to: 0, duration: 1, waitForDisplay: false, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(fake.helperCalls == [
            ["hinge-sweep", "0.0", "180.0", "0.400"],
            ["hinge-sweep", "180.0", "0.0", "1.000"],
        ])
    }

    @Test("An unreadable angle still sweeps")
    func unreadableStillSweeps() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot90"))
        fake.angleReadings = [.unreadable("timed out"), .angle(180)]

        try await FoldableDevice.moveHinge(from: nil, to: 180, duration: 0, waitForDisplay: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(fake.helperCalls == [["hinge-sweep", "0.0", "180.0", "0.400"]])
    }

    @Test("No hinge: nothing is sent")
    func noHinge() async {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.noHinge]

        await #expect(throws: CLIError.self) {
            try await FoldableDevice.moveHinge(from: nil, to: 0, duration: 0, waitForDisplay: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)
        }
        #expect(fake.helperCalls.isEmpty)
    }

    @Test("An angle that never arrives fails")
    func angleNotConfirmed() async {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.angle(180)]

        do {
            try await FoldableDevice.moveHinge(from: nil, to: 0, duration: 0, waitForDisplay: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("did not reach 0.0 degrees"))
        }
    }

    @Test("A display that does not switch fails and names the active display")
    func displayDoesNotSwitch() async {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot90"))
        fake.angleReadings = [.angle(180), .angle(0)]

        do {
            try await FoldableDevice.moveHinge(from: nil, to: 0, duration: 0, waitForDisplay: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("The cover display did not become active"))
            #expect(error.localizedDescription.contains("LCD-1"))
        }
    }

    @Test("--no-wait skips the display check")
    func noWait() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot90"))
        fake.angleReadings = [.angle(180), .angle(0)]

        try await FoldableDevice.moveHinge(from: nil, to: 0, duration: 0, waitForDisplay: false, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)
    }

    @Test("Hinge commands on non-foldables fail before the helper is involved")
    func nonFoldableDecision() throws {
        #expect(throws: CLIError.self) {
            try FoldableDevice.ensureHingeSupported(isFoldable: false, simulatorUDID: "SIMULATOR_UDID")
        }
        try FoldableDevice.ensureHingeSupported(isFoldable: true, simulatorUDID: "SIMULATOR_UDID")
        #expect(DeviceStateAction.hinge(target: 0, duration: 0, waitForDisplay: true).isHingeAction)
        #expect(DeviceStateAction.sweep(from: 0, to: 180, duration: 0, waitForDisplay: true).isHingeAction)
        #expect(!DeviceStateAction.rotate(.portrait).isHingeAction)
    }
}

@Suite("Rotation")
@MainActor
struct RotationFlowTests {
    /// Rotation of the unfolded Duo's inner display for each helper device orientation, measured on iOS 27.2.
    private static let innerRotation = ["portrait": "rot90", "landscape-left": "rot0", "landscape-right": "rot180", "pud": "rot270"]

    /// Applies `rotations` to the fake's inner display after each orientation event.
    private func follow(_ rotations: [String: String], on fake: FakeSimulator) {
        fake.onHelper = { [unowned fake] arguments in
            if arguments.first == "orientation", let rotation = rotations[arguments[1]] {
                fake.displayState = duoState(active: .inner, rotation: rotation)
            }
        }
    }

    @Test("Foldable: tries device orientations in order until the rotation matches")
    func foldableSearch() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot90", deviceOrientation: "landscapeRight"))
        follow(Self.innerRotation, on: fake)

        try await FoldableDevice.rotateFoldable(to: .portrait, driver: fake.driver)

        #expect(fake.helperCalls == [["orientation", "portrait"], ["orientation", "landscape-left"]])
    }

    @Test("Foldable: the device orientation devicectl reports does not limit the search")
    func foldableSearchIgnoresDeviceOrientationName() async throws {
        // devicectl reports `portrait` here although the helper value that produced rot0 was landscape-left.
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot0", deviceOrientation: "portrait"))
        follow(Self.innerRotation, on: fake)

        try await FoldableDevice.rotateFoldable(to: .landscape, driver: fake.driver)

        #expect(fake.helperCalls == [["orientation", "portrait"]])
    }

    @Test("Foldable: already at the target sends nothing")
    func foldableNoOp() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot90"))

        try await FoldableDevice.rotateFoldable(to: .landscape, driver: fake.driver)

        #expect(fake.helperCalls.isEmpty)
    }

    @Test("Foldable: a slow rotation within the poll window still matches")
    func foldableSlowRotation() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot90", deviceOrientation: "landscapeRight"))
        var reads = 0
        fake.onHelper = { _ in reads = 0 }
        let slow = FoldableDriver(
            readAngle: fake.driver.readAngle,
            runHelper: fake.driver.runHelper,
            readDisplays: {
                reads += 1
                // The rotation shows up on the fifth read (about 1 s), after a fixed 0.6 s settle would have given up.
                return reads >= 5
                    ? duoState(active: .inner, rotation: "rot0", deviceOrientation: "portrait")
                    : duoState(active: .inner, rotation: "rot90", deviceOrientation: "landscapeRight")
            },
            setDeviceOrientation: fake.driver.setDeviceOrientation,
            readDeviceOrientation: fake.driver.readDeviceOrientation,
            sleep: fake.driver.sleep,
            now: fake.driver.now,
            log: { _ in }
        )

        try await FoldableDevice.rotateFoldable(to: .portrait, driver: slow)

        #expect(fake.helperCalls == [["orientation", "portrait"]])
    }

    @Test("Foldable: no match returns the display to its starting rotation and fails")
    func foldableRestoreOnFailure() async {
        // The foreground app does not support upside down: landscape-right leaves the display as it is.
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot0", deviceOrientation: "portrait"))
        follow(["portrait": "rot90", "landscape-left": "rot0", "pud": "rot270"], on: fake)

        do {
            try await FoldableDevice.rotateFoldable(to: .portraitUpsideDown, driver: fake.driver)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("did not rotate to portrait-upside-down"))
            #expect(error.localizedDescription.contains("returned to rot0"))
        }
        #expect(fake.helperCalls == [
            ["orientation", "portrait"],
            ["orientation", "landscape-left"],
            ["orientation", "landscape-right"],
            ["orientation", "pud"],
            ["orientation", "portrait"],
            ["orientation", "landscape-left"],
        ])
        #expect(fake.displayState.activeDisplay?.currentRotation == .rot0)
    }

    @Test("Single display: landscape sets device landscapeRight and checks the display rotation")
    func singleDisplayLandscape() async throws {
        let fake = FakeSimulator(displayState: singleState(rotation: "rot0"))
        fake.onSetDeviceOrientation = { [unowned fake] value in
            fake.reportedDeviceOrientation = value
            fake.displayState = singleState(rotation: value == "landscapeRight" ? "rot90" : "rot270")
        }

        let warning = try await FoldableDevice.rotateSingleDisplay(to: .landscape, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(warning == nil)
        #expect(fake.deviceOrientationsSet == ["landscapeRight"])
    }

    @Test("Single display: an interface that does not rotate gives a warning")
    func singleDisplayNoRotation() async throws {
        let fake = FakeSimulator(displayState: singleState(rotation: "rot0"))
        fake.onSetDeviceOrientation = { [unowned fake] value in fake.reportedDeviceOrientation = value }

        let warning = try await FoldableDevice.rotateSingleDisplay(to: .landscapeFlipped, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(fake.deviceOrientationsSet == ["landscapeLeft"])
        #expect(warning?.contains("may not support landscape-flipped") == true)
    }

    @Test("Single display: a device that ignores the orientation fails")
    func singleDisplayIgnored() async {
        let fake = FakeSimulator(displayState: singleState(rotation: "rot0"))
        fake.reportedDeviceOrientation = "portrait"

        await #expect(throws: CLIError.self) {
            try await FoldableDevice.rotateSingleDisplay(to: .landscape, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)
        }
    }
}

@Suite("Interface orientation")
struct InterfaceOrientationTests {
    @Test(
        "Interface orientation maps to devicectl device orientation (landscape is rot90 / UIKit uiOrientation 3)",
        arguments: [
            (InterfaceOrientation.portrait, "portrait"),
            (.landscape, "landscapeRight"),
            (.portraitUpsideDown, "portraitUpsideDown"),
            (.landscapeFlipped, "landscapeLeft"),
        ]
    )
    func deviceOrientation(orientation: InterfaceOrientation, expected: String) {
        #expect(orientation.deviceOrientation == expected)
    }

    @Test(
        "Rotation and interface orientation round-trip",
        arguments: [
            (SimulatorDisplay.Rotation.rot0, InterfaceOrientation.portrait),
            (.rot90, .landscape),
            (.rot180, .portraitUpsideDown),
            (.rot270, .landscapeFlipped),
        ]
    )
    func rotationMapping(rotation: SimulatorDisplay.Rotation, expected: InterfaceOrientation) {
        #expect(InterfaceOrientation(rotation: rotation) == expected)
        #expect(expected.rotation == rotation)
    }

    @Test("Foldable search order matches Device Hub's device orientation values")
    func searchOrder() {
        #expect(InterfaceOrientation.foldableSearchOrder == ["portrait", "landscape-left", "landscape-right", "pud"])
    }

    @Test("Parses kebab-case arguments")
    func parsesArguments() {
        #expect(InterfaceOrientation(argument: "portrait-upside-down") == .portraitUpsideDown)
        #expect(InterfaceOrientation(argument: "landscape-flipped") == .landscapeFlipped)
        #expect(InterfaceOrientation(argument: "landscapeLeft") == nil)
    }

    @Test("Decodes devicectl orientation get output")
    func decodesDeviceOrientation() throws {
        let json = #"{"info":{"outcome":"success","jsonVersion":5},"result":{"deviceOrientation":"unknown","deviceOrientationNonFlat":"landscapeLeft"}}"#
        #expect(try DeviceOrientationEnvelope.decode(from: Data(json.utf8)) == "landscapeLeft")
    }
}

@Suite("Posture")
struct PostureTests {
    @Test("Folded Duo posture encodes to the fixture")
    func foldedDuoJSON() throws {
        let posture = DevicePosture(udid: "SIMULATOR_UDID", hingeAngle: 0, state: try devicectlFixture("duo-folded"))
        let expectedURL = try #require(
            Bundle.module.url(forResource: "duo-folded", withExtension: "json", subdirectory: "Fixtures/posture")
        )

        let encoded = try jsonObject(Data(try posture.jsonString().utf8))
        let expected = try jsonObject(Data(contentsOf: expectedURL))

        #expect(encoded == expected)
        #expect(posture.activePanel == .cover)
    }

    @Test("Unfolded Duo: inner display active with a landscape interface size")
    func unfoldedDuo() throws {
        let posture = DevicePosture(udid: "SIMULATOR_UDID", hingeAngle: 180, state: try devicectlFixture("duo-unfolded"))
        let active = try #require(posture.activeDisplay)

        #expect(active.id == 3)
        #expect(active.role == .inner)
        #expect(active.rotation == "rot90")
        #expect(active.interfaceOrientation == .landscape)
        #expect(active.sizePoints == DevicePosture.Size(width: 951, height: 669))
        #expect(posture.activePanel == .inner)
    }

    @Test("Single display: null hinge angle and a main display")
    func singleDisplay() throws {
        let posture = DevicePosture(udid: "SIMULATOR_UDID", hingeAngle: nil, state: try devicectlFixture("single-display"))

        #expect(posture.displays.count == 1)
        #expect(posture.activeDisplay?.role == .main)
        #expect(posture.activePanel == nil)

        let encoded = try jsonObject(Data(try posture.jsonString().utf8))
        #expect(encoded["hingeAngle"] is NSNull)
    }
}

@Suite("Simulator helper")
struct SimHelperTests {
    private let developerDirectory = "/Applications/Xcode.app/Contents/Developer"

    private func key(
        source: String = "int main(void) { return 0; }",
        developerDirectory: String? = nil,
        xcodeBuild: String = "27C100",
        architecture: String = "arm64",
        compileFlags: String = "-O2"
    ) -> String {
        SimHelper.cacheKey(
            source: Data(source.utf8),
            developerDirectory: developerDirectory ?? self.developerDirectory,
            xcodeBuild: xcodeBuild,
            architecture: architecture,
            compileFlags: compileFlags
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axe-sim-helper-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Cache key is 12 hex digits and changes with each input")
    func cacheKey() {
        let base = key()

        #expect(base.count == 12)
        #expect(base.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(base == key())
        #expect(base != key(source: "int main(void) { return 1; }"))
        #expect(base != key(developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer"))
        #expect(base != key(xcodeBuild: "27C101"))
        #expect(base != key(architecture: "x86_64"))
        #expect(base != key(compileFlags: "-O0"))
    }

    @Test("Inputs are separated so concatenations do not collide")
    func cacheKeySeparatesInputs() {
        #expect(key(source: "ab", developerDirectory: "c") != key(source: "a", developerDirectory: "bc"))
    }

    @Test("Compile flags exclude paths and include the architecture")
    func compileFlags() {
        let flags = SimHelper.compileFlags(architecture: "arm64")

        #expect(flags.contains("-arch arm64"))
        #expect(flags.contains("-mios-simulator-version-min=17.0"))
        #expect(flags != SimHelper.compileFlags(architecture: "x86_64"))
    }

    @Test("Xcode build comes from Info.plist, then version.plist")
    func xcodeBuild() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let developer = root.appendingPathComponent("Developer", isDirectory: true)

        #expect(SimHelper.xcodeBuild(developerDirectory: developer.path) == "unknown")

        try (["ProductBuildVersion": "27C99"] as NSDictionary).write(to: root.appendingPathComponent("version.plist"))
        #expect(SimHelper.xcodeBuild(developerDirectory: developer.path) == "27C99")

        try (["DTXcodeBuild": "27C100"] as NSDictionary).write(to: root.appendingPathComponent("Info.plist"))
        #expect(SimHelper.xcodeBuild(developerDirectory: developer.path) == "27C100")
    }

    @Test("Architecture follows the host")
    func architecture() {
        #expect(SimHelper.architecture(isAppleSilicon: true) == "arm64")
        #expect(SimHelper.architecture(isAppleSilicon: false) == "x86_64")
    }

    @Test("Compile arguments target the iphonesimulator SDK")
    func compileArguments() {
        let arguments = SimHelper.compileArguments(source: "helper.m", output: "helper", architecture: "arm64")

        #expect(Array(arguments.prefix(3)) == ["-sdk", "iphonesimulator", "clang"])
        #expect(arguments.contains("-mios-simulator-version-min=17.0"))
        #expect(arguments.contains("CoreMotion"))
        #expect(arguments.suffix(3) == ["helper.m", "-o", "helper"])
    }

    @Test("Compile failures report the first error line, not a warning")
    func compileFailureDetail() {
        let stderr = """
            helper.m:10:5: warning: unused variable 'x'
            helper.m:12:1: error: expected ';' after expression
            1 warning and 1 error generated.
            """
        #expect(SimHelper.compileFailureDetail(standardError: Data(stderr.utf8)) == "helper.m:12:1: error: expected ';' after expression")
        #expect(SimHelper.compileFailureDetail(standardError: Data("\nsomething odd\n".utf8)) == "something odd")
        #expect(SimHelper.compileFailureDetail(standardError: Data()) == "")
    }

    @Test("AXE_SIM_HELPER_PATH: unset, not executable, executable")
    func overridePath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        try Data("#!/bin/sh\n".utf8).write(to: helper)

        #expect(try SimHelper.overrideURL(environment: [:]) == nil)
        #expect(try SimHelper.overrideURL(environment: ["AXE_SIM_HELPER_PATH": "  "]) == nil)
        #expect(throws: CLIError.self) {
            try SimHelper.overrideURL(environment: ["AXE_SIM_HELPER_PATH": helper.path])
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        #expect(try SimHelper.overrideURL(environment: ["AXE_SIM_HELPER_PATH": helper.path])?.path == helper.path)
    }

    @Test("Install renames the staging file over the destination")
    func atomicInstall() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("axe-sim-helper")
        let staging = root.appendingPathComponent("axe-sim-helper.staging.tmp")
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: staging)

        try SimHelper.install(staging: staging, at: destination)

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(throws: CLIError.self) {
            try SimHelper.install(staging: staging, at: destination)
        }
    }

    @Test("Spawned helpers get a self-termination deadline")
    func spawnArguments() {
        #expect(SimHelper.spawnArguments(["hinge-angle"], timeout: 10) == ["--deadline", "10", "hinge-angle"])
        #expect(SimHelper.spawnArguments(["hinge-sweep", "0.0", "180.0", "0.400"], timeout: 10.4) == ["--deadline", "11", "hinge-sweep", "0.0", "180.0", "0.400"])
    }

    @Test("The helper source ships in the resource bundle")
    func bundledSource() throws {
        let url = try #require(SimHelper.bundledSourceURL())
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.contains("com.apple.Virtualization.VirtualMachines"))
        #expect(source.contains("com.apple.Virtualization\""))
        #expect(source.contains("hinge-slider-control"))
        #expect(source.contains("--deadline"))
    }
}

@Suite("Hinge, posture and rotate arguments")
struct FoldableArgumentTests {
    @Test("hinge set parses the angle and options")
    func hingeSet() throws {
        let command = try #require(try Hinge.parseAsRoot(["set", "130", "--duration", "1.5", "--no-wait", "--udid", "SIMULATOR_UDID"]) as? Hinge.SetAngle)

        #expect(command.degrees == 130)
        #expect(command.action == .hinge(target: 130, duration: 1.5, waitForDisplay: false))
    }

    @Test("hinge set rejects 200 degrees")
    func hingeSetRejectsOutOfRange() {
        #expect(throws: (any Error).self) {
            try Hinge.parseAsRoot(["set", "200", "--udid", "SIMULATOR_UDID"])
        }
    }

    @Test(
        "open, close and half map to 180, 0 and 90",
        arguments: [("open", 180.0), ("close", 0), ("half", 90)]
    )
    func presets(name: String, degrees: Double) throws {
        let command = try #require(try Hinge.parseAsRoot([name, "--udid", "SIMULATOR_UDID"]) as? any HingeMoving)

        #expect(command.action == .hinge(target: degrees, duration: 0, waitForDisplay: true))
    }

    @Test("hinge sweep validates both angles")
    func sweep() throws {
        let command = try #require(try Hinge.parseAsRoot(["sweep", "180", "0", "--duration", "2", "--udid", "SIMULATOR_UDID"]) as? Hinge.Sweep)

        #expect(command.action == .sweep(from: 180, to: 0, duration: 2, waitForDisplay: true))
        #expect(throws: (any Error).self) {
            try Hinge.parseAsRoot(["sweep", "0", "181", "--udid", "SIMULATOR_UDID"])
        }
    }

    @Test("hinge --duration accepts 0 to 30 seconds", arguments: [("-1", false), ("0", true), ("30", true), ("30.5", false)])
    func durationRange(value: String, valid: Bool) {
        let parse = { try Hinge.parseAsRoot(["open", "--duration", value, "--udid", "SIMULATOR_UDID"]) }
        if valid {
            #expect(throws: Never.self) { _ = try parse() }
        } else {
            #expect(throws: (any Error).self) { _ = try parse() }
        }
    }

    @Test("hinge get and posture parse --json")
    func getAndPosture() throws {
        let get = try #require(try Hinge.parseAsRoot(["get", "--json", "--udid", "SIMULATOR_UDID"]) as? Hinge.Get)
        #expect(get.json)

        let posture = try Posture.parse(["--udid", "SIMULATOR_UDID"])
        #expect(!posture.json)
    }

    @Test("rotate parses interface orientations and rejects device names")
    func rotate() throws {
        #expect(try Rotate.parse(["landscape", "--udid", "SIMULATOR_UDID"]).orientation == .landscape)
        #expect(try Rotate.parse(["portrait-upside-down", "--udid", "SIMULATOR_UDID"]).orientation == .portraitUpsideDown)
        #expect(throws: (any Error).self) {
            try Rotate.parse(["landscape-left", "--udid", "SIMULATOR_UDID"])
        }
    }
}

@Suite("Batch hinge and rotate steps")
@MainActor
struct BatchDeviceStateStepTests {
    private func parse(_ tokens: [String]) async throws -> [BatchPrimitive] {
        let context = BatchContext(
            simulatorUDID: "SIMULATOR_UDID",
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200
        )
        return try await BatchStepParser.parseStepTokens(tokens, globalUDID: "SIMULATOR_UDID", context: context, logger: AxeLogger())
    }

    private func action(_ primitives: [BatchPrimitive]) throws -> DeviceStateAction {
        #expect(primitives.count == 1)
        guard case .deviceState(let action) = try #require(primitives.first) else {
            Issue.record("Expected a device-state primitive")
            throw ValidationError("not a device-state primitive")
        }
        return action
    }

    /// The text `axe batch` prints for a failing step.
    private func failureMessage(_ tokens: [String]) async -> String? {
        do {
            _ = try await parse(tokens)
            return nil
        } catch {
            return Batch.stepFailureMessage(for: error)
        }
    }

    @Test("hinge open, close, half and set become barrier steps")
    func hingeSteps() async throws {
        #expect(try action(try await parse(["hinge", "open"])) == .hinge(target: 180, duration: 0, waitForDisplay: true))
        #expect(try action(try await parse(["hinge", "close", "--duration", "1"])) == .hinge(target: 0, duration: 1, waitForDisplay: true))
        #expect(try action(try await parse(["hinge", "half"])) == .hinge(target: 90, duration: 0, waitForDisplay: true))
        #expect(try action(try await parse(["hinge", "set", "130", "--no-wait"])) == .hinge(target: 130, duration: 0, waitForDisplay: false))
    }

    @Test("Invalid hinge steps are rejected", arguments: [
        ["hinge"],
        ["hinge", "set"],
        ["hinge", "set", "200"],
        ["hinge", "get"],
        ["hinge", "sweep", "0", "180"],
        ["hinge", "open", "--json"],
        ["hinge", "open", "--udid", "OTHER"],
    ])
    func invalidHingeSteps(tokens: [String]) async {
        await #expect(throws: (any Error).self) {
            try await parse(tokens)
        }
    }

    @Test("rotate becomes a barrier step")
    func rotateStep() async throws {
        #expect(try action(try await parse(["rotate", "landscape"])) == .rotate(.landscape))
        await #expect(throws: (any Error).self) {
            try await parse(["rotate", "sideways"])
        }
        await #expect(throws: (any Error).self) {
            try await parse(["rotate", "landscape", "--json"])
        }
    }

    @Test("Step failures show the parser's message")
    func stepFailureMessages() async {
        let sweep = await failureMessage(["hinge", "sweep", "0", "180"])
        #expect(sweep?.contains(BatchStepParser.hingeStepFormat) == true)

        let json = await failureMessage(["hinge", "open", "--json"])
        #expect(json == "--json is not supported in batch hinge steps.")

        let rotateJSON = await failureMessage(["rotate", "landscape", "--json"])
        #expect(rotateJSON == "--json is not supported in batch rotate steps.")

        let sideways = await failureMessage(["rotate", "sideways"])
        #expect(sideways?.contains(BatchStepParser.rotateStepFormat) == true)
        #expect(sideways?.contains("sideways") == true)

        let unsupported = await failureMessage(["fold"])
        #expect(unsupported == "Unsupported batch step 'fold'.")

        for message in [sweep, json, rotateJSON, sideways, unsupported] {
            #expect(message?.contains("couldn’t be completed") == false)
        }
    }

    @Test("Failure messages unwrap ValidationError and CLIError")
    func messageUnwrapping() {
        #expect(Batch.stepFailureMessage(for: ValidationError("bad step")) == "bad step")
        #expect(Batch.stepFailureMessage(for: CLIError(errorDescription: "AXe failed")) == "AXe failed")
    }
}
