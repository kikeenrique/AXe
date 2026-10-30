import ArgumentParser
import FBControlCore
import FBSimulatorControl
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

private func makeDisplay(id: Int, primary: Bool, active: Bool?, rotation: String) -> AXe.SimulatorDisplay {
    AXe.SimulatorDisplay(
        displayId: id,
        name: primary ? "LCD" : "LCD-1",
        uniqueId: "00000000-0000-0000-0000-00000000000\(id)",
        primary: primary,
        active: active,
        backlightState: active == true ? "activeOn" : "off",
        currentOrientation: rotation,
        nativeSize: primary ? AXe.SimulatorDisplay.Size(width: 1398, height: 2034) : AXe.SimulatorDisplay.Size(width: 2007, height: 2853),
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
    var anglesSet: [Double] = []
    var deviceOrientationsSet: [SimulatorDeviceOrientation] = []
    var reportedDeviceOrientation: SimulatorDeviceOrientation?
    /// Called after each device orientation set; may change `displayState`.
    var onSetDeviceOrientation: (SimulatorDeviceOrientation) -> Void = { _ in }

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
            setAngle: { [unowned self] degrees in anglesSet.append(degrees) },
            readDisplays: { [unowned self] _ in displayState },
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

    @Test("Sweep duration has a 0.4 s floor before iOS 27.2", arguments: [(0.0, 0.4), (0.1, 0.4), (0.4, 0.4), (1.5, 1.5)])
    func sweepDurationFloor(requested: Double, expected: Double) {
        #expect(HingeRules.sweepDuration(requested: requested) == expected)
    }

    @Test("Runtimes that take direct sets keep the requested duration", arguments: [0.0, 0.1, 1.5])
    func sweepDurationDirect(requested: Double) {
        #expect(HingeRules.sweepDuration(requested: requested, directSetAllowed: true) == requested)
    }

    @Test(
        "Direct sets from iOS 27.2",
        arguments: [((27, 1), false), ((27, 2), true), ((27, 3), true), ((28, 0), true), ((26, 5), false)]
    )
    func directSetRuntime(version: (Int, Int), expected: Bool) {
        let runtime = OperatingSystemVersion(majorVersion: version.0, minorVersion: version.1, patchVersion: 0)
        #expect(HingeRules.allowsDirectSet(runtime: runtime) == expected)
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

    @Test("Eased angles start and end at the endpoints and stay in range")
    func easedAngle() {
        #expect(HingeRules.easedAngle(from: 180, to: 0, progress: 0) == 180)
        #expect(HingeRules.easedAngle(from: 180, to: 0, progress: 0.5) == 90)
        #expect(HingeRules.easedAngle(from: 180, to: 0, progress: 1) == 0)
        #expect(HingeRules.easedAngle(from: 0, to: 180, progress: 2) == 180)
        #expect(HingeRules.easedAngle(from: 0, to: 180, progress: 0.1) < 18)
    }
}

@Suite("Hinge sweep plan")
struct HingeSweepPlanTests {
    @Test("set sweeps from the current angle")
    func setFromCurrent() {
        let plan = HingeRules.sweepPlan(current: 180, start: nil, target: 0, duration: 0)

        #expect(plan == [HingeSweep(from: 180, to: 0, duration: 0.4)])
        #expect(!plan[0].isDirectSet)
    }

    @Test("set is one direct set on runtimes that take it")
    func setDirect() {
        let plan = HingeRules.sweepPlan(current: 180, start: nil, target: 0, duration: 0, directSetAllowed: true)

        #expect(plan == [HingeSweep(from: 180, to: 0, duration: 0)])
        #expect(plan[0].isDirectSet)
        #expect(HingeRules.sweepPlan(current: 180, start: nil, target: 0, duration: 1, directSetAllowed: true) == [HingeSweep(from: 180, to: 0, duration: 1)])
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

    @Test("sweep always sweeps, and moves to <from> directly on runtimes that take direct sets")
    func sweepDirectStart() {
        let plan = HingeRules.sweepPlan(current: 0, start: 180, target: 0, duration: 0, directSetAllowed: true)

        #expect(plan == [
            HingeSweep(from: 0, to: 180, duration: 0),
            HingeSweep(from: 180, to: 0, duration: 0.4),
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
    @Test("close: one eased sweep from the current angle, angle confirmed, cover awaited")
    func closeFromOpen() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.angle(180), .angle(0)]

        try await FoldableDevice.moveHinge(from: nil, to: 0, duration: 0, waitForDisplay: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        // 0.4 s at 30 Hz from 180 down to exactly 0, never more than 10 degrees per angle, so
        // at least 18 steps.
        #expect(fake.anglesSet.count >= 19)
        #expect(fake.anglesSet.first == 180)
        #expect(fake.anglesSet.last == 0)
        #expect(zip(fake.anglesSet, fake.anglesSet.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(zip(fake.anglesSet, fake.anglesSet.dropFirst()).allSatisfy { $0 - $1 <= HingeRules.maximumSweepStep })
    }

    @Test("A slow host makes the sweep longer, never a jump")
    func slowSetAngleSweep() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.angle(180), .angle(0)]
        var slow = fake.driver
        // Each set takes 0.2 s: a time-sliced 0.4 s sweep would send about three angles.
        slow.setAngle = { [unowned fake] degrees in
            fake.anglesSet.append(degrees)
            fake.time = fake.time.addingTimeInterval(0.2)
        }

        try await FoldableDevice.moveHinge(from: nil, to: 0, duration: 0, waitForDisplay: false, simulatorUDID: "SIMULATOR_UDID", driver: slow)

        let steps = zip(fake.anglesSet, fake.anglesSet.dropFirst()).map { abs($0 - $1) }
        #expect(fake.anglesSet.first == 180)
        #expect(fake.anglesSet.last == 0)
        #expect(fake.anglesSet.count >= 19)
        #expect(steps.allSatisfy { $0 <= HingeRules.maximumSweepStep })
    }

    @Test("The display wait keeps polling while the displays are still changing")
    func displayWaitSurvivesTransition() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.angle(0), .angle(180)]
        var reads = 0
        var driver = fake.driver
        driver.readDisplays = { _ in
            reads += 1
            if reads < 3 {
                throw DisplaysStillChangingError(simulatorUDID: "SIMULATOR_UDID", budget: 1)
            }
            return duoState(active: .inner, rotation: "rot90")
        }

        try await FoldableDevice.moveHinge(from: nil, to: 180, duration: 0, waitForDisplay: true, directSetAllowed: true, simulatorUDID: "SIMULATOR_UDID", driver: driver)

        #expect(reads == 3)
    }

    @Test("The display wait passes the remaining time as the settle budget")
    func displayWaitBudget() async {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.angle(0), .angle(180)]
        var budgets: [TimeInterval] = []
        var driver = fake.driver
        driver.readDisplays = { [unowned fake] budget in
            budgets.append(budget)
            return fake.displayState
        }

        await #expect(throws: CLIError.self) {
            try await FoldableDevice.moveHinge(from: nil, to: 180, duration: 0, waitForDisplay: true, directSetAllowed: true, simulatorUDID: "SIMULATOR_UDID", driver: driver)
        }
        #expect(budgets.first.map { $0 <= HingeRules.displaySwitchTimeout } == true)
        #expect(zip(budgets, budgets.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test("close on a runtime that takes direct sets: one set")
    func closeDirect() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.angle(180), .angle(0)]

        try await FoldableDevice.moveHinge(from: nil, to: 0, duration: 0, waitForDisplay: true, directSetAllowed: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(fake.anglesSet == [0])
    }

    @Test("sweep from a different angle moves to <from> first")
    func sweepFromElsewhere() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.angle(0), .angle(0)]

        try await FoldableDevice.moveHinge(from: 180, to: 0, duration: 1, waitForDisplay: false, directSetAllowed: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(fake.anglesSet.first == 180)
        #expect(fake.anglesSet.dropFirst().first == 180)
        #expect(fake.anglesSet.last == 0)
        // One direct set to 180, then 1 s at 30 Hz.
        #expect((1 + 31...1 + 32).contains(fake.anglesSet.count))
    }

    @Test("An unreadable angle still sweeps")
    func unreadableStillSweeps() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot90"))
        fake.angleReadings = [.unreadable("timed out"), .angle(180)]

        try await FoldableDevice.moveHinge(from: nil, to: 180, duration: 0, waitForDisplay: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(fake.anglesSet.first == 0)
        #expect(fake.anglesSet.last == 180)
        #expect(fake.anglesSet.count > 1)
    }

    @Test("No hinge: nothing is sent")
    func noHinge() async {
        let fake = FakeSimulator(displayState: duoState(active: .cover))
        fake.angleReadings = [.noHinge]

        await #expect(throws: CLIError.self) {
            try await FoldableDevice.moveHinge(from: nil, to: 0, duration: 0, waitForDisplay: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)
        }
        #expect(fake.anglesSet.isEmpty)
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

    @Test("Hinge commands on simulators without a hinge fail before anything is sent")
    func nonFoldableDecision() throws {
        #expect(throws: CLIError.self) {
            try FoldableDevice.ensureHingeSupported(hasHinge: false, simulatorUDID: "SIMULATOR_UDID")
        }
        try FoldableDevice.ensureHingeSupported(hasHinge: true, simulatorUDID: "SIMULATOR_UDID")
        #expect(DeviceStateAction.hinge(target: 0, duration: 0, waitForDisplay: true).isHingeAction)
        #expect(DeviceStateAction.sweep(from: 0, to: 180, duration: 0, waitForDisplay: true).isHingeAction)
        #expect(!DeviceStateAction.rotate(.portrait).isHingeAction)
    }
}

@Suite("Rotation")
@MainActor
struct RotationFlowTests {
    /// Rotation of the unfolded Duo's inner display for each device orientation, measured on iOS 27.2.
    private static let innerRotation: [SimulatorDeviceOrientation: String] = [
        .portrait: "rot90", .landscapeLeft: "rot0", .landscapeRight: "rot180", .portraitUpsideDown: "rot270",
    ]

    /// Applies `rotations` to the fake's inner display after each orientation event.
    private func follow(_ rotations: [SimulatorDeviceOrientation: String], on fake: FakeSimulator) {
        fake.onSetDeviceOrientation = { [unowned fake] value in
            if let rotation = rotations[value] {
                fake.displayState = duoState(active: .inner, rotation: rotation)
            }
        }
    }

    @Test("Foldable: tries the mapped device orientation, then the others, until the rotation matches")
    func foldableSearch() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot90", deviceOrientation: "landscapeRight"))
        follow(Self.innerRotation, on: fake)

        let warning = try await FoldableDevice.rotate(to: .portrait, isFoldable: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(warning == nil)
        #expect(fake.deviceOrientationsSet == [.portrait, .landscapeLeft])
    }

    @Test("Foldable: the mapped device orientation is tried first")
    func foldableMappedFirst() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot0", deviceOrientation: "portrait"))
        follow(Self.innerRotation, on: fake)

        _ = try await FoldableDevice.rotate(to: .portraitUpsideDown, isFoldable: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(fake.deviceOrientationsSet == [.portraitUpsideDown, .portrait, .landscapeLeft, .landscapeRight])
    }

    @Test("Foldable: already at the target sends nothing")
    func foldableNoOp() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot90"))

        _ = try await FoldableDevice.rotate(to: .landscape, isFoldable: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(fake.deviceOrientationsSet.isEmpty)
    }

    @Test("Foldable: a slow rotation within the poll window still matches")
    func foldableSlowRotation() async throws {
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot90", deviceOrientation: "landscapeRight"))
        var reads = 0
        fake.onSetDeviceOrientation = { _ in reads = 0 }
        var slow = fake.driver
        slow.readDisplays = { _ in
            reads += 1
            // The rotation shows up on the fifth read (about 1 s), after a fixed 0.6 s settle would have given up.
            return reads >= 5
                ? duoState(active: .inner, rotation: "rot180", deviceOrientation: "portrait")
                : duoState(active: .inner, rotation: "rot90", deviceOrientation: "landscapeRight")
        }

        _ = try await FoldableDevice.rotate(to: .portraitUpsideDown, isFoldable: true, simulatorUDID: "SIMULATOR_UDID", driver: slow)

        #expect(fake.deviceOrientationsSet == [.portraitUpsideDown])
    }

    @Test("Foldable: no match returns the display to its starting rotation and fails")
    func foldableRestoreOnFailure() async {
        // The foreground app does not support upside down: landscapeRight leaves the display as it is.
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot0", deviceOrientation: "portrait"))
        follow([.portrait: "rot90", .landscapeLeft: "rot0", .portraitUpsideDown: "rot270"], on: fake)

        do {
            _ = try await FoldableDevice.rotate(to: .portraitUpsideDown, isFoldable: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("did not rotate to portrait-upside-down"))
            #expect(error.localizedDescription.contains("returned to rot0"))
        }
        #expect(fake.deviceOrientationsSet == [
            .portraitUpsideDown, .portrait, .landscapeLeft, .landscapeRight,
            .portrait, .landscapeLeft,
        ])
        #expect(fake.displayState.activeDisplay?.currentRotation == .rot0)
    }

    @Test("Foldable: on failure the original device orientation is set back first")
    func foldableRestoresDeviceOrientation() async {
        // Started at device landscapeLeft (inner rot0). portrait would also give the cover its
        // original rotation only by chance; setting landscapeLeft back restores both panels.
        let fake = FakeSimulator(displayState: duoState(active: .inner, rotation: "rot0", deviceOrientation: "landscapeLeft"))
        fake.reportedDeviceOrientation = .landscapeLeft
        follow([.portrait: "rot90", .landscapeLeft: "rot0", .portraitUpsideDown: "rot270"], on: fake)

        do {
            _ = try await FoldableDevice.rotate(to: .portraitUpsideDown, isFoldable: true, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("device orientation was returned to landscapeLeft"))
        }
        #expect(fake.deviceOrientationsSet == [
            .portraitUpsideDown, .portrait, .landscapeLeft, .landscapeRight,
            .landscapeLeft,
        ])
        #expect(fake.displayState.activeDisplay?.currentRotation == .rot0)
    }

    @Test("Single display without identified displays rotates without a warning")
    func unidentifiedSingleDisplay() async throws {
        func state(_ rotation: String) -> SimulatorDisplayState {
            SimulatorDisplayState(
                idbDisplays: [],
                unidentifiedDisplay: SimulatorDisplayState.unidentifiedDisplay(
                    rotation: rotation,
                    pixelSize: AXe.SimulatorDisplay.Size(width: 1206, height: 2622),
                    scale: 3
                )
            )
        }
        let fake = FakeSimulator(displayState: state("rot0"))
        fake.onSetDeviceOrientation = { [unowned fake] value in
            fake.reportedDeviceOrientation = value
            fake.displayState = state(value == .landscapeRight ? "rot90" : "rot270")
        }

        let warning = try await FoldableDevice.rotate(to: .landscape, isFoldable: false, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(warning == nil)
        #expect(fake.deviceOrientationsSet == [.landscapeRight])
    }

    @Test("Single display: landscape sets device landscapeRight and checks the display rotation")
    func singleDisplayLandscape() async throws {
        let fake = FakeSimulator(displayState: singleState(rotation: "rot0"))
        fake.onSetDeviceOrientation = { [unowned fake] value in
            fake.reportedDeviceOrientation = value
            fake.displayState = singleState(rotation: value == .landscapeRight ? "rot90" : "rot270")
        }

        let warning = try await FoldableDevice.rotate(to: .landscape, isFoldable: false, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(warning == nil)
        #expect(fake.deviceOrientationsSet == [.landscapeRight])
    }

    @Test("Single display: an interface that does not rotate gives a warning")
    func singleDisplayNoRotation() async throws {
        let fake = FakeSimulator(displayState: singleState(rotation: "rot0"))
        fake.onSetDeviceOrientation = { [unowned fake] value in fake.reportedDeviceOrientation = value }

        let warning = try await FoldableDevice.rotate(to: .landscapeFlipped, isFoldable: false, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)

        #expect(fake.deviceOrientationsSet == [.landscapeLeft])
        #expect(warning?.contains("may not support landscape-flipped") == true)
        #expect(warning?.contains("landscapeLeft") == true)
    }

    @Test("Single display: a device that ignores the orientation fails")
    func singleDisplayIgnored() async {
        let fake = FakeSimulator(displayState: singleState(rotation: "rot0"))
        fake.reportedDeviceOrientation = .portrait

        await #expect(throws: CLIError.self) {
            try await FoldableDevice.rotate(to: .landscape, isFoldable: false, simulatorUDID: "SIMULATOR_UDID", driver: fake.driver)
        }
    }
}

@Suite("Interface orientation")
struct InterfaceOrientationTests {
    @Test(
        "Interface orientation maps to device orientation (landscape is device landscapeRight, rot90)",
        arguments: [
            (InterfaceOrientation.portrait, "portrait"),
            (.landscape, "landscapeRight"),
            (.portraitUpsideDown, "portraitUpsideDown"),
            (.landscapeFlipped, "landscapeLeft"),
        ]
    )
    func deviceOrientation(orientation: InterfaceOrientation, expected: String) {
        #expect(orientation.deviceOrientation.rawValue == expected)
        #expect(orientation.candidateDeviceOrientations(isFoldable: false).map(\.rawValue) == [expected])
    }

    @Test(
        "Rotation and interface orientation round-trip",
        arguments: [
            (AXe.SimulatorDisplay.Rotation.rot0, InterfaceOrientation.portrait),
            (.rot90, .landscape),
            (.rot180, .portraitUpsideDown),
            (.rot270, .landscapeFlipped),
        ]
    )
    func rotationMapping(rotation: AXe.SimulatorDisplay.Rotation, expected: InterfaceOrientation) {
        #expect(InterfaceOrientation(rotation: rotation) == expected)
        #expect(expected.rotation == rotation)
    }

    @Test("Foldable candidates: the mapped device orientation, then the others in search order")
    func searchOrder() {
        #expect(InterfaceOrientation.foldableSearchOrder == [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown])
        #expect(InterfaceOrientation.landscape.candidateDeviceOrientations(isFoldable: true) == [.landscapeRight, .portrait, .landscapeLeft, .portraitUpsideDown])
        #expect(InterfaceOrientation.portrait.candidateDeviceOrientations(isFoldable: true) == InterfaceOrientation.foldableSearchOrder)
    }

    @Test("Parses kebab-case arguments")
    func parsesArguments() {
        #expect(InterfaceOrientation(argument: "portrait-upside-down") == .portraitUpsideDown)
        #expect(InterfaceOrientation(argument: "landscape-flipped") == .landscapeFlipped)
        #expect(InterfaceOrientation(argument: "landscapeLeft") == nil)
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

    @Test("Without devicectl the backlight and device orientation read unknown; the JSON keeps nulls")
    func devicectlUnavailable() throws {
        let idbOnly = SimulatorDisplayState(displays: try devicectlFixture("duo-folded").displays.map { display in
            AXe.SimulatorDisplay(
                displayId: display.displayId,
                name: display.name,
                uniqueId: display.uniqueId,
                primary: display.primary,
                active: display.active,
                backlightState: nil,
                currentOrientation: display.currentOrientation,
                nativeSize: display.nativeSize,
                pointScale: display.pointScale
            )
        })
        let posture = DevicePosture(udid: "SIMULATOR_UDID", hingeAngle: 0, state: idbOnly, devicectlUnavailable: true)

        #expect(posture.textSummary.contains("device orientation: unknown"))
        #expect(posture.textSummary.contains("backlight unknown"))
        #expect(posture.activePanel == .cover)
        let encoded = try jsonObject(Data(try posture.jsonString().utf8))
        #expect(encoded["deviceOrientation"] is NSNull)
        #expect(encoded["devicectlUnavailable"] == nil)
    }

    @Test("devicectl state takes activity, rotation and size from IDB and keeps IDs, backlight and device orientation")
    func overlaying() throws {
        let devicectl = try devicectlFixture("duo-folded")
        var idbDisplays = devicectl.displays.map { display in
            AXe.SimulatorDisplay(
                displayId: AXe.SimulatorDisplay.unknownDisplayID,
                name: display.name,
                uniqueId: display.uniqueId,
                primary: display.primary,
                active: !display.primary,
                backlightState: nil,
                currentOrientation: display.primary ? "rot0" : "rot270",
                nativeSize: display.nativeSize,
                pointScale: display.pointScale
            )
        }
        idbDisplays.append(makeDisplay(id: 9, primary: false, active: false, rotation: "rot0"))
        let merged = devicectl.overlaying(SimulatorDisplayState(displays: idbDisplays))
        let inner = try #require(merged.displays.first { !$0.primary })

        #expect(merged.displays.count == devicectl.displays.count)
        #expect(merged.displays.map(\.displayId) == devicectl.displays.map(\.displayId))
        #expect(merged.deviceOrientation == devicectl.deviceOrientation)
        #expect(merged.activeDisplay?.uniqueId == inner.uniqueId)
        #expect(inner.currentOrientation == "rot270")
        #expect(inner.backlightState == devicectl.displays.first { !$0.primary }?.backlightState)
    }
}

// The display ID cache tests live in SimulatorDisplaysTests.swift ("Display ID cache and lookup"),
// in one serialized suite, because the cache is process-wide state.

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
