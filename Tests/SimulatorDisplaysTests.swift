import ArgumentParser
import Foundation
import Testing
@testable import AXe

// Fixtures in Fixtures/devicectl mirror `xcrun devicectl device info displays -j -` output
// (jsonVersion 5) from an iPhone Duo on Xcode 27.2, with placeholder UUIDs. The
// missing-active fixture is synthetic: it drops the `active` flags and adds a non-integrated display.

private func fixtureState(_ name: String) throws -> SimulatorDisplayState {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/devicectl")
    )
    return try SimulatorDisplayState.decode(from: Data(contentsOf: url))
}

private func display(
    id: Int,
    name: String,
    primary: Bool,
    active: Bool?,
    backlight: String?,
    orientation: String? = "rot0"
) -> SimulatorDisplay {
    SimulatorDisplay(
        displayId: id,
        name: name,
        uniqueId: "00000000-0000-0000-0000-00000000000\(id)",
        primary: primary,
        active: active,
        backlightState: backlight,
        currentOrientation: orientation,
        nativeSize: SimulatorDisplay.Size(width: 1398, height: 2034),
        pointScale: 3
    )
}

@Suite("Simulator display decoding")
struct SimulatorDisplayDecodingTests {
    @Test("Unfolded Duo decodes both integrated displays")
    func decodesUnfoldedDuo() throws {
        let state = try fixtureState("duo-unfolded")

        #expect(state.displays.count == 2)
        #expect(state.isMultiDisplay)
        #expect(state.deviceOrientation == "portrait")

        let cover = try #require(state.displays.first { $0.displayId == 1 })
        #expect(cover.name == "LCD")
        #expect(cover.uniqueId == "00000000-0000-0000-0000-000000000001")
        #expect(cover.primary)
        #expect(cover.active == false)
        #expect(cover.backlightState == "off")
        #expect(cover.currentRotation == .rot0)
        #expect(cover.nativeSize == SimulatorDisplay.Size(width: 1398, height: 2034))
        #expect(cover.bounds == SimulatorDisplay.Size(width: 1398, height: 2034))
        #expect(cover.pointScale == 3)
        #expect(cover.isIntegrated)

        let inner = try #require(state.displays.first { $0.displayId == 3 })
        #expect(inner.name == "LCD-1")
        #expect(!inner.primary)
        #expect(inner.active == true)
        #expect(inner.currentRotation == .rot90)
        #expect(inner.nativeSizePoints == SimulatorDisplay.Size(width: 669, height: 951))
    }

    @Test("Single-display device has no active flag")
    func decodesSingleDisplay() throws {
        let state = try fixtureState("single-display")

        #expect(state.displays.count == 1)
        #expect(!state.isMultiDisplay)
        #expect(state.displays[0].active == nil)
        #expect(state.coverDisplay == nil)
        #expect(state.innerDisplay == nil)
    }

    @Test("Non-integrated displays are dropped")
    func dropsNonIntegratedDisplays() throws {
        let state = try fixtureState("duo-missing-active")

        #expect(state.displays.map(\.displayId) == [1, 3])
    }

    @Test("A failed devicectl outcome throws")
    func failedOutcomeThrows() {
        let data = Data(#"{"info":{"outcome":"failed","jsonVersion":5}}"#.utf8)

        #expect(throws: CLIError.self) {
            try SimulatorDisplayState.decode(from: data)
        }
    }

    @Test("Unknown rotation strings decode without a rotation")
    func unknownRotation() {
        let unknown = display(id: 1, name: "LCD", primary: true, active: true, backlight: "activeOn", orientation: "rotX")

        #expect(unknown.currentRotation == nil)
    }
}

@Suite("Active display selection")
struct ActiveDisplaySelectionTests {
    @Test("Unfolded Duo: the inner display is active")
    func unfoldedSelectsInner() throws {
        let active = try #require(try fixtureState("duo-unfolded").activeDisplay)

        #expect(active.displayId == 3)
        #expect(!active.primary)
    }

    @Test("Folded Duo: the cover display is active")
    func foldedSelectsCover() throws {
        let active = try #require(try fixtureState("duo-folded").activeDisplay)

        #expect(active.displayId == 1)
        #expect(active.primary)
    }

    @Test("A single display without an active flag is active")
    func singleDisplayIsActive() throws {
        let active = try #require(try fixtureState("single-display").activeDisplay)

        #expect(active.displayId == 1)
    }

    @Test("Without active flags, the display with a lit backlight is active")
    func missingActiveUsesBacklight() throws {
        let active = try #require(try fixtureState("duo-missing-active").activeDisplay)

        #expect(active.displayId == 3)
    }

    @Test("Without active flags or a single lit backlight, no display is active")
    func ambiguousStateHasNoActiveDisplay() {
        let state = SimulatorDisplayState(displays: [
            display(id: 1, name: "LCD", primary: true, active: nil, backlight: "inactiveOn"),
            display(id: 3, name: "LCD-1", primary: false, active: nil, backlight: "off"),
        ])

        #expect(state.activeDisplay == nil)
    }

    @Test("The active flag wins over the backlight")
    func activeFlagWinsOverBacklight() {
        let state = SimulatorDisplayState(displays: [
            display(id: 1, name: "LCD", primary: true, active: false, backlight: "activeOn"),
            display(id: 3, name: "LCD-1", primary: false, active: true, backlight: "off"),
        ])

        #expect(state.activeDisplay?.displayId == 3)
    }
}

@Suite("Display selection option")
struct DisplaySelectionTests {
    @Test(
        "Parses --display values",
        arguments: [
            ("auto", DisplaySelection.auto),
            ("AUTO", .auto),
            ("cover", .cover),
            (" inner ", .inner),
            ("3", .id(3)),
            ("LCD-1", .name("LCD-1")),
            ("00000000-0000-0000-0000-000000000003", .name("00000000-0000-0000-0000-000000000003")),
        ]
    )
    func parsesArgument(raw: String, expected: DisplaySelection) {
        #expect(DisplaySelection(argument: raw) == expected)
    }

    @Test("Rejects empty and negative values", arguments: ["", "   ", "-1"])
    func rejectsInvalidArgument(raw: String) {
        #expect(DisplaySelection(argument: raw) == nil)
    }

    @Test("Screenshot defaults to auto")
    func screenshotDefaultsToAuto() throws {
        let command = try Screenshot.parse(["--udid", "SIMULATOR_UDID"])

        #expect(command.display == .auto)
    }

    @Test("Screenshot parses --display")
    func screenshotParsesDisplay() throws {
        let command = try Screenshot.parse(["--udid", "SIMULATOR_UDID", "--display", "cover"])

        #expect(command.display == .cover)
    }

    @Test("Screenshot rejects an empty --display")
    func screenshotRejectsEmptyDisplay() {
        #expect(throws: (any Error).self) {
            try Screenshot.parse(["--udid", "SIMULATOR_UDID", "--display", ""])
        }
    }

    @Test("Resolves selections against an unfolded Duo")
    func resolvesSelections() throws {
        let state = try fixtureState("duo-unfolded")

        #expect(try DisplaySelection.auto.resolve(in: state).displayId == 3)
        #expect(try DisplaySelection.cover.resolve(in: state).displayId == 1)
        #expect(try DisplaySelection.inner.resolve(in: state).displayId == 3)
        #expect(try DisplaySelection.id(1).resolve(in: state).displayId == 1)
        #expect(try DisplaySelection.name("lcd-1").resolve(in: state).displayId == 3)
        #expect(try DisplaySelection.name("00000000-0000-0000-0000-000000000001").resolve(in: state).displayId == 1)
    }

    @Test("Unknown displays throw")
    func unknownDisplayThrows() throws {
        let state = try fixtureState("duo-unfolded")

        #expect(throws: CLIError.self) { try DisplaySelection.id(9).resolve(in: state) }
        #expect(throws: CLIError.self) { try DisplaySelection.name("TVOut").resolve(in: state) }
    }

    @Test("cover and inner need a foldable")
    func coverAndInnerNeedFoldable() throws {
        let state = try fixtureState("single-display")

        #expect(throws: CLIError.self) { try DisplaySelection.cover.resolve(in: state) }
        #expect(throws: CLIError.self) { try DisplaySelection.inner.resolve(in: state) }
        #expect(try DisplaySelection.auto.resolve(in: state).displayId == 1)
    }
}

@Suite("Display probe policy")
struct DisplayProbePolicyTests {
    private let duo = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
    private let iPhone = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"

    @Test("Reads AXE_DISPLAY_PROBE")
    func readsEnvironment() {
        #expect(DisplayProbePolicy.current(environment: [:]) == .auto)
        #expect(DisplayProbePolicy.current(environment: ["AXE_DISPLAY_PROBE": "never"]) == .never)
        #expect(DisplayProbePolicy.current(environment: ["AXE_DISPLAY_PROBE": " Always "]) == .always)
        #expect(DisplayProbePolicy.current(environment: ["AXE_DISPLAY_PROBE": "bogus"]) == .auto)
    }

    @Test("auto probes foldable device types only")
    func autoProbesFoldablesOnly() {
        #expect(DisplayProbePolicy.auto.shouldProbe(deviceTypeIdentifier: duo))
        #expect(!DisplayProbePolicy.auto.shouldProbe(deviceTypeIdentifier: iPhone))
        #expect(!DisplayProbePolicy.auto.shouldProbe(deviceTypeIdentifier: nil))
    }

    @Test("always and never override the device type")
    func overrides() {
        #expect(DisplayProbePolicy.always.shouldProbe(deviceTypeIdentifier: iPhone))
        #expect(!DisplayProbePolicy.never.shouldProbe(deviceTypeIdentifier: duo))
    }
}

@Suite("Display state cache")
struct DisplayStateCacheTests {
    @Test("Each batch step starts without cached display state")
    @MainActor
    func batchStepClearsCachedState() throws {
        let udid = "SIMULATOR_UDID"
        SimulatorDisplays.cacheState(try fixtureState("duo-folded"), forSimulatorUDID: udid)
        #expect(SimulatorDisplays.cachedState(forSimulatorUDID: udid) != nil)

        Batch.beginStep()

        #expect(SimulatorDisplays.cachedState(forSimulatorUDID: udid) == nil)
    }

    @Test("A client policy overrides the process environment")
    @MainActor
    func policyOverride() {
        defer { SimulatorDisplays.policyOverride = nil }

        SimulatorDisplays.policyOverride = .never
        #expect(SimulatorDisplays.policy == .never)
        SimulatorDisplays.policyOverride = .always
        #expect(SimulatorDisplays.policy == .always)
        SimulatorDisplays.policyOverride = nil
        #expect(SimulatorDisplays.policy == DisplayProbePolicy.current())
    }
}

@Suite("Screenshot capture decision")
struct DisplayCaptureTests {
    @Test("A capture is kept after a runner failure only when simctl wrote a PNG")
    func pngDetection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-png-detection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]).write(to: png)
        #expect(SimulatorDisplays.isPNGFile(at: png))

        let truncated = directory.appendingPathComponent("short.png")
        try Data([0x89, 0x50]).write(to: truncated)
        #expect(!SimulatorDisplays.isPNGFile(at: truncated))

        let text = directory.appendingPathComponent("text.png")
        try Data("not a png".utf8).write(to: text)
        #expect(!SimulatorDisplays.isPNGFile(at: text))

        #expect(!SimulatorDisplays.isPNGFile(at: directory.appendingPathComponent("missing.png")))
    }

    @Test("Without display state, auto uses the framebuffer and IDs or names pass through")
    func noState() throws {
        #expect(try DisplayCapture.resolve(selection: .auto, state: nil) == .framebuffer)
        #expect(try DisplayCapture.resolve(selection: .id(3), state: nil) == .unvalidatedDisplay("3"))
        #expect(try DisplayCapture.resolve(selection: .name("LCD-1"), state: nil) == .unvalidatedDisplay("LCD-1"))
    }

    @Test("Without display state, cover and inner fail", arguments: [DisplaySelection.cover, .inner])
    func noStateCoverInner(selection: DisplaySelection) {
        #expect(throws: CLIError.self) {
            try DisplayCapture.resolve(selection: selection, state: nil)
        }
    }

    @Test("A foldable with the probe disabled names the override")
    func probeDisabledMessage() {
        do {
            _ = try DisplayCapture.resolve(selection: .cover, state: nil, isFoldableWithProbeDisabled: true)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("AXE_DISPLAY_PROBE=never"))
        }
    }

    @Test("A single display (AXE_DISPLAY_PROBE=always) keeps the framebuffer for auto only")
    func singleDisplay() throws {
        let state = try fixtureState("single-display")

        #expect(try DisplayCapture.resolve(selection: .auto, state: state) == .framebuffer)
        guard case .display(let display) = try DisplayCapture.resolve(selection: .id(1), state: state) else {
            Issue.record("Expected a resolved display")
            return
        }
        #expect(display.displayId == 1)
        #expect(throws: CLIError.self) { try DisplayCapture.resolve(selection: .cover, state: state) }
    }

    @Test(
        "An unfolded foldable resolves every selection to a display",
        arguments: [
            (DisplaySelection.auto, 3),
            (.cover, 1),
            (.inner, 3),
            (.id(1), 1),
            (.name("LCD-1"), 3),
        ]
    )
    func unfoldedFoldable(selection: DisplaySelection, expectedID: Int) throws {
        let capture = try DisplayCapture.resolve(selection: selection, state: fixtureState("duo-unfolded"))

        guard case .display(let display) = capture else {
            Issue.record("Expected a resolved display, got \(capture)")
            return
        }
        #expect(display.displayId == expectedID)
    }

    @Test("A folded foldable captures the cover for auto")
    func foldedFoldable() throws {
        let capture = try DisplayCapture.resolve(selection: .auto, state: fixtureState("duo-folded"))

        #expect(capture == .display(try #require(try fixtureState("duo-folded").coverDisplay)))
    }
}

@Suite("xcrun failure detail")
struct XcrunFailureDetailTests {
    // Captured from devicectl 651.31 (Xcode 27.2) for an unknown device, with a placeholder UDID.
    private let devicectlStandardError = """
        ERROR: The specified device was not found. (Name: 00000000-0000-0000-0000-000000000000) (com.apple.dt.CoreDeviceError error 1000 (0x3E8))
               DeviceName = 00000000-0000-0000-0000-000000000000

        """
    private let devicectlStandardOutput = """
        {
          "error" : {
            "code" : 1000,
            "domain" : "com.apple.dt.CoreDeviceError",
            "userInfo" : {
              "DeviceName" : {
                "string" : "00000000-0000-0000-0000-000000000000"
              },
              "NSLocalizedDescription" : {
                "string" : "The specified device was not found. (Name: 00000000-0000-0000-0000-000000000000)"
              }
            }
          },
          "errorSignature" : "(com.apple.dt.CoreDeviceError 1000)",
          "info" : {
            "commandType" : "devicectl.device.info.displays",
            "jsonVersion" : 5,
            "outcome" : "failed",
            "version" : "651.31"
          }
        }

        """
    // Captured from `simctl io <udid> screenshot --display=9` on an iPhone Duo (exit 22).
    private let simctlStandardError = """
        Detected file type from extension: PNG
        Error: Device does not have a '9' display port

        An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=22):
        Device does not have a '9' display port
        Invalid argument

        """
    private let expectedDevicectlMessage = "The specified device was not found. (Name: 00000000-0000-0000-0000-000000000000)"

    @Test("devicectl: the JSON NSLocalizedDescription on stdout wins")
    func devicectlJSONOnStdout() {
        let detail = XcrunFailureDetail.summary(
            standardOutput: Data(devicectlStandardOutput.utf8),
            standardError: Data(devicectlStandardError.utf8)
        )

        #expect(detail == expectedDevicectlMessage)
    }

    @Test("devicectl: JSON appended to stderr is decoded")
    func devicectlJSONOnStandardError() {
        let detail = XcrunFailureDetail.summary(
            standardOutput: Data(),
            standardError: Data((devicectlStandardError + devicectlStandardOutput).utf8)
        )

        #expect(detail == expectedDevicectlMessage)
    }

    @Test("devicectl: without JSON, the ERROR: line is used without its prefix")
    func devicectlErrorLine() {
        let detail = XcrunFailureDetail.summary(standardOutput: Data(), standardError: Data(devicectlStandardError.utf8))

        #expect(detail.hasPrefix("The specified device was not found."))
        #expect(detail != "}")
    }

    @Test("simctl: the Error: line wins over progress and errno lines")
    func simctlErrorLine() {
        let detail = XcrunFailureDetail.summary(standardOutput: Data(), standardError: Data(simctlStandardError.utf8))

        #expect(detail == "Device does not have a '9' display port")
    }

    @Test("Falls back to the first non-empty stderr line")
    func firstLineFallback() {
        let detail = XcrunFailureDetail.summary(standardOutput: Data(), standardError: Data("\n  first problem\nsecond\n".utf8))

        #expect(detail == "first problem")
        #expect(XcrunFailureDetail.summary(standardOutput: Data(), standardError: Data()) == "")
    }

    @Test("A failed devicectl envelope reports its description")
    func failedEnvelopeMessage() {
        do {
            _ = try SimulatorDisplayState.decode(from: Data(devicectlStandardOutput.utf8))
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("failed"))
            #expect(error.localizedDescription.contains("The specified device was not found."))
        }
    }
}

@Suite("Tolerant geometry decoding")
struct TolerantDecodingTests {
    @Test("Unexpected geometry shapes decode as nil instead of failing")
    func unexpectedGeometry() throws {
        let json = """
            {"info":{"outcome":"success","jsonVersion":6},"result":{"displays":[
              {"displayId":1,"name":"LCD","primary":true,"active":true,"backlightState":"activeOn",
               "nativeSize":{"width":1398,"height":2034},"bounds":"0,0,1398,2034","pointScale":"3",
               "currentOrientation":0,"type":{"integrated":{}}}
            ]}}
            """
        let state = try SimulatorDisplayState.decode(from: Data(json.utf8))
        let display = try #require(state.activeDisplay)

        #expect(state.jsonVersion == 6)
        #expect(display.displayId == 1)
        #expect(display.nativeSize == nil)
        #expect(display.bounds == nil)
        #expect(display.pointScale == nil)
        #expect(display.currentOrientation == nil)
    }
}

/// `state` as IDB reports it when devicectl's numeric IDs are unavailable: every display ID unknown.
private func withoutDisplayIDs(_ state: SimulatorDisplayState) -> SimulatorDisplayState {
    SimulatorDisplayState(displays: state.displays.map { display in
        SimulatorDisplay(
            displayId: SimulatorDisplay.unknownDisplayID,
            name: display.name,
            uniqueId: display.uniqueId,
            primary: display.primary,
            active: display.active,
            backlightState: nil,
            currentOrientation: display.currentOrientation,
            nativeSize: display.nativeSize,
            pointScale: display.pointScale,
            bounds: display.bounds
        )
    })
}

@Suite("Displays without devicectl IDs")
struct UnknownDisplayIDTests {
    @Test("Touch target: the inactive panel's point size is still foreign")
    func touchTargetForeignSizes() throws {
        let withIDs = try #require(try TouchTarget.resolve(state: fixtureState("duo-unfolded")))
        let target = try #require(try TouchTarget.resolve(state: withoutDisplayIDs(try fixtureState("duo-unfolded"))))

        // The cover's 466x678 pt must be filtered on the inner display either way.
        #expect(target.foreignWindowSizes.contains(SimulatorDisplay.Size(width: 466, height: 678)))
        #expect(target.foreignWindowSizes == withIDs.foreignWindowSizes)
    }

    @Test("stream-video refuses the inactive display")
    func streamRefusesInactiveDisplay() throws {
        let folded = withoutDisplayIDs(try fixtureState("duo-folded"))

        do {
            try StreamCapture.validate(selection: .inner, state: folded)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("is not active"))
            #expect(error.localizedDescription.contains("LCD-1"))
            #expect(!error.localizedDescription.contains("-1 (LCD"))
            #expect(error.localizedDescription.contains("--display LCD-1"))
        }
        try StreamCapture.validate(selection: .cover, state: folded)
    }

    @Test("stream-video compares displays by unique ID with known IDs too")
    func streamWithIDs() throws {
        let folded = try fixtureState("duo-folded")

        #expect(throws: CLIError.self) { try StreamCapture.validate(selection: .inner, state: folded) }
        try StreamCapture.validate(selection: .id(1), state: folded)
    }

    @Test("--display <id> says the numeric IDs are unavailable and names the displays")
    func numericSelectionWithoutIDs() throws {
        let state = withoutDisplayIDs(try fixtureState("duo-unfolded"))

        do {
            _ = try DisplaySelection.id(3).resolve(in: state)
            Issue.record("Expected an error")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("could not read the numeric display IDs"))
            #expect(message.contains("LCD-1 (00000000-0000-0000-0000-000000000003)"))
            #expect(!message.contains(" -1 ("))
        }
        #expect(try DisplaySelection.name("LCD-1").resolve(in: state).uniqueId == "00000000-0000-0000-0000-000000000003")
    }

    @Test("An inactive explicit capture warns with the display name")
    func inactiveWarning() throws {
        let inner = try #require(withoutDisplayIDs(try fixtureState("duo-folded")).innerDisplay)

        let warning = DisplayCapture.inactiveDisplayWarning(for: inner, selection: .inner)
        #expect(warning == "Warning: display LCD-1 (00000000-0000-0000-0000-000000000003) is not active; the capture may be black.")
    }

    @Test("Posture marks only the active display active")
    func postureActiveByUniqueID() throws {
        let posture = DevicePosture(udid: "SIMULATOR_UDID", hingeAngle: 0, state: withoutDisplayIDs(try fixtureState("duo-folded")))

        #expect(posture.displays.filter(\.active).count == 1)
        #expect(posture.activeDisplay?.role == .cover)
        #expect(posture.textSummary.contains("(id unknown, cover, primary)"))
    }
}

@Suite("Unidentified single display")
struct UnidentifiedDisplayTests {
    private let sole = SimulatorDisplayState.unidentifiedDisplay(
        rotation: "rot90",
        pixelSize: SimulatorDisplay.Size(width: 1206, height: 2622),
        scale: 3
    )

    @Test("A runtime that identifies no displays still yields its sole display")
    func soleDisplay() throws {
        let state = SimulatorDisplayState(idbDisplays: [], unidentifiedDisplay: sole)
        let active = try #require(state.activeDisplay)

        #expect(state.displays.count == 1)
        #expect(!state.isMultiDisplay)
        #expect(active.currentRotation == .rot90)
        #expect(active.nativeSizePoints == SimulatorDisplay.Size(width: 402, height: 874))
        #expect(!active.hasKnownDisplayID)
    }

    @Test("Identified displays win over the unidentified geometry")
    func identifiedWins() throws {
        let identified = try fixtureState("duo-unfolded").displays
        let state = SimulatorDisplayState(idbDisplays: identified.reversed(), unidentifiedDisplay: sole)

        #expect(state.displays.map(\.displayId) == [1, 3])
    }

    @Test("No displays and no geometry stay empty")
    func empty() {
        #expect(SimulatorDisplayState(idbDisplays: [], unidentifiedDisplay: nil).displays.isEmpty)
    }
}

@Suite("Display ID cache and lookup", .serialized)
@MainActor
struct DisplayIDLookupTests {
    @Test("Stores devicectl IDs by unique ID on disk and reads them back")
    func roundTrip() async throws {
        try await withEmptyCache {
            #expect(DisplayIDCache.ids(forSimulatorUDID: udid) == nil)
            let ids = DisplayIDCache.store(try fixtureState("duo-unfolded"), forSimulatorUDID: udid)
            #expect(Set(ids.values) == [1, 3])

            DisplayIDCache.clearMemory()
            #expect(DisplayIDCache.ids(forSimulatorUDID: udid) == ids)
        }
    }

    @Test("A lookup failure is remembered in memory only")
    func unavailableIsInMemory() async {
        await withEmptyCache {
            DisplayIDCache.markLookupUnavailable(forSimulatorUDID: udid)
            #expect(DisplayIDCache.isLookupUnavailable(forSimulatorUDID: udid))
            DisplayIDCache.clearMemory()
            #expect(!DisplayIDCache.isLookupUnavailable(forSimulatorUDID: udid))
        }
    }

    private let udid = "SIMULATOR_UDID_LOOKUP"
    private let cover = "00000000-0000-0000-0000-000000000001"
    private let inner = "00000000-0000-0000-0000-000000000003"

    /// Runs `body` with the cache in a fresh directory and empty memory.
    private func withEmptyCache(_ body: () async throws -> Void) async rethrows {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axe-display-ids-\(UUID().uuidString)", isDirectory: true)
        let previous = DisplayIDCache.directory
        DisplayIDCache.directory = directory
        DisplayIDCache.clearMemory()
        defer {
            DisplayIDCache.directory = previous
            DisplayIDCache.clearMemory()
            try? FileManager.default.removeItem(at: directory)
        }
        try await body()
    }

    @Test("A cache hit does not run devicectl")
    func cacheHit() async throws {
        try await withEmptyCache {
            DisplayIDCache.store(try fixtureState("duo-unfolded"), forSimulatorUDID: udid)
            var lookups = 0
            let ids = await SimulatorDisplays.displayIDs(needed: [cover, inner], simulatorUDID: udid, logger: AxeLogger()) { _, _ in
                lookups += 1
                throw CLIError(errorDescription: "unexpected")
            }

            #expect(ids == [cover: 1, inner: 3])
            #expect(lookups == 0)
        }
    }

    @Test("A display missing from the cache refreshes it once")
    func subsetMissRefreshes() async throws {
        try await withEmptyCache {
            DisplayIDCache.store(try fixtureState("single-display"), forSimulatorUDID: udid)
            var lookups = 0
            let lookup: SimulatorDisplays.DisplayIDLookup = { _, _ in
                lookups += 1
                return try fixtureState("duo-unfolded")
            }

            let ids = await SimulatorDisplays.displayIDs(needed: [cover, inner], simulatorUDID: udid, logger: AxeLogger(), lookup: lookup)
            let again = await SimulatorDisplays.displayIDs(needed: [cover, inner], simulatorUDID: udid, logger: AxeLogger(), lookup: lookup)

            #expect(ids[inner] == 3)
            #expect(again == ids)
            #expect(lookups == 1)
        }
    }

    @Test("A failed lookup is not repeated in the same process")
    func failureIsRemembered() async {
        await withEmptyCache {
            var lookups = 0
            let failing: SimulatorDisplays.DisplayIDLookup = { _, _ in
                lookups += 1
                throw CLIError(errorDescription: "devicectl timed out")
            }

            for _ in 0..<3 {
                let ids = await SimulatorDisplays.displayIDs(needed: [cover, inner], simulatorUDID: udid, logger: AxeLogger(), lookup: failing)
                #expect(ids.isEmpty)
            }

            #expect(lookups == 1)
            #expect(DisplayIDCache.isLookupUnavailable(forSimulatorUDID: udid))
        }
    }

    @Test("Nothing needed: devicectl does not run")
    func nothingNeeded() async {
        await withEmptyCache {
            var lookups = 0
            let ids = await SimulatorDisplays.displayIDs(needed: [], simulatorUDID: udid, logger: AxeLogger()) { _, _ in
                lookups += 1
                throw CLIError(errorDescription: "unexpected")
            }

            #expect(ids.isEmpty)
            #expect(lookups == 0)
        }
    }

    @Test("A still-changing configuration error asks to retry")
    func stillChangingMessage() {
        let message = DisplaysStillChangingError(simulatorUDID: "SIMULATOR_UDID", budget: 10).localizedDescription

        #expect(message.contains("still changing after 10 s"))
        #expect(message.contains("try again"))
    }
}

@Suite("Display rotation")
struct DisplayRotationTests {
    @Test(
        "Rotations map to UI orientations",
        arguments: [
            (SimulatorDisplay.Rotation.rot0, SimulatorOrientation.portrait),
            (.rot90, .landscape),
            (.rot180, .portraitUpsideDown),
            (.rot270, .landscapeFlipped),
        ]
    )
    func rotationMapping(rotation: SimulatorDisplay.Rotation, expected: SimulatorOrientation) {
        #expect(rotation.simulatorOrientation == expected)
    }
}
