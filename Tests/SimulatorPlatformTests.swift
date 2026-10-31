import ArgumentParser
import FBControlCore
import FBSimulatorControl
import Foundation
import Testing
@testable import AXe

private func platformRoots(_ json: String) throws -> [AccessibilityElement] {
    try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
}

@Suite("Simulator platform derivation")
struct SimulatorPlatformDerivationTests {
    @Test(
        "Product families IDB knows decide the platform",
        arguments: [
            (ProductFamily.iPhone, SimulatorPlatform.iOS),
            (.iPad, .iOS),
            (.appleWatch, .watchOS),
            (.appleTV, .tvOS),
        ]
    )
    func productFamily(family: ProductFamily, expected: SimulatorPlatform) {
        #expect(SimulatorPlatform.derive(family: family, runtimeIdentifier: nil, runtimeName: nil) == expected)
    }

    @Test("Apple Vision Pro (product family 7, unknown to IDB) is visionOS from its xrOS runtime")
    func visionFromRuntimeIdentifier() {
        #expect(SimulatorPlatform.derive(
            family: .unknown,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.xrOS-27-2",
            runtimeName: "visionOS 27.2"
        ) == .visionOS)
    }

    @Test(
        "Runtime identifiers name the platform when the family is unknown",
        arguments: [
            ("com.apple.CoreSimulator.SimRuntime.iOS-27-2", SimulatorPlatform.iOS),
            ("com.apple.CoreSimulator.SimRuntime.watchOS-27-2", .watchOS),
            ("com.apple.CoreSimulator.SimRuntime.tvOS-27-2", .tvOS),
            ("com.apple.CoreSimulator.SimRuntime.xrOS-27-2", .visionOS),
            ("com.example.Unrelated", .unknown),
        ]
    )
    func runtimeIdentifier(identifier: String, expected: SimulatorPlatform) {
        #expect(SimulatorPlatform.derive(family: .unknown, runtimeIdentifier: identifier, runtimeName: nil) == expected)
    }

    @Test("The runtime name is the last resort")
    func runtimeName() {
        #expect(SimulatorPlatform.derive(family: .unknown, runtimeIdentifier: nil, runtimeName: "visionOS 27.2") == .visionOS)
        #expect(SimulatorPlatform.derive(family: .unknown, runtimeIdentifier: nil, runtimeName: "watchOS 27.2") == .watchOS)
        #expect(SimulatorPlatform.derive(family: .unknown, runtimeIdentifier: nil, runtimeName: "unknown") == .unknown)
    }

    @Test("The mac family falls through to the runtime, and is unknown without one")
    func macFamily() {
        #expect(SimulatorPlatform.derive(family: .mac, runtimeIdentifier: nil, runtimeName: nil) == .unknown)
        #expect(SimulatorPlatform.derive(
            family: .mac,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
            runtimeName: nil
        ) == .iOS)
        #expect(SimulatorPlatform.derive(family: .mac, runtimeIdentifier: "com.example.Unrelated", runtimeName: "tvOS 27.2") == .tvOS)
        #expect(SimulatorPlatform.derive(family: .mac, runtimeIdentifier: nil, runtimeName: "iPadOS 27.2") == .iOS)
        #expect(SimulatorPlatform.derive(family: .mac, runtimeIdentifier: nil, runtimeName: "macOS 27.0") == .unknown)
    }

    @Test("The product family wins over a conflicting runtime")
    func familyWins() {
        #expect(SimulatorPlatform.derive(
            family: .appleWatch,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
            runtimeName: "iOS 27.2"
        ) == .watchOS)
    }

    @Test("A configuration derives its platform")
    func fromConfiguration() {
        let configuration = SimulatorConfiguration(
            device: DeviceType(model: DeviceModel(rawValue: "Apple Vision Pro"), family: .unknown),
            os: OSVersion(name: OSVersionName(rawValue: "visionOS 27.2")),
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.xrOS-27-2"
        )
        #expect(SimulatorPlatform(configuration: configuration) == .visionOS)
    }

    @Test("list-simulators appends the platform and keeps IDB's fields byte for byte")
    func listSimulatorsLine() {
        let description = "00000000-0000-0000-0000-000000000000 | Apple Watch | Booted | Apple Watch | OS 'watchOS 27.2' "
        #expect(
            ListSimulators.line(description: description, platform: .watchOS)
                == "00000000-0000-0000-0000-000000000000 | Apple Watch | Booted | Apple Watch | OS 'watchOS 27.2' | Platform 'watchOS'"
        )
        #expect(ListSimulators.line(description: "A | B", platform: .iOS) == "A | B | Platform 'iOS'")
    }
}

@Suite("Platform input gating")
struct PlatformInputGatingTests {
    private func message(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as CLIError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test("iOS and watchOS take touch, buttons and keyboard; tvOS keyboard and buttons only")
    func acceptedInputs() throws {
        for platform in [SimulatorPlatform.iOS, .watchOS, .unknown] {
            for input in [PlatformSupport.Input.touch, .button, .keyboard] {
                try PlatformSupport.check(input, on: platform)
            }
        }
        try PlatformSupport.check(.keyboard, on: .tvOS)
        try PlatformSupport.check(.button, on: .tvOS)
        try PlatformSupport.check(.remote, on: .tvOS)
    }

    @Test("tvOS refuses touch with the remote hint")
    func tvOSTouch() {
        #expect(message { try PlatformSupport.check(.touch, on: .tvOS) } == "Touch input is not available on tvOS simulators; use `axe remote`")
    }

    @Test("visionOS refuses every kind of HID input with one message", arguments: [PlatformSupport.Input.touch, .button, .keyboard])
    func visionOSInput(input: PlatformSupport.Input) {
        #expect(message { try PlatformSupport.check(input, on: .visionOS) } == PlatformSupport.visionOSInputUnsupportedMessage)
        #expect(PlatformSupport.visionOSInputUnsupportedMessage.hasPrefix("Input is not supported on visionOS simulators"))
        #expect(PlatformSupport.visionOSInputUnsupportedMessage.contains("the bundled IDB"))
    }

    @Test("remote is tvOS only", arguments: [SimulatorPlatform.iOS, .watchOS, .visionOS, .unknown])
    func remoteOnTVOSOnly(platform: SimulatorPlatform) {
        let text = message { try PlatformSupport.check(.remote, on: platform) }
        #expect(text?.hasPrefix("Remote is only available on tvOS simulators") == true)
        #expect(text?.contains("this simulator runs \(platform.phrase))") == true)
    }

    @Test("An unrecognised platform is worded as such, never as 'unknown'")
    func unrecognisedWording() {
        #expect(SimulatorPlatform.unknown.phrase == "an unrecognised platform")
        #expect(SimulatorPlatform.watchOS.phrase == "watchOS")
        let text = message { try PlatformSupport.check(.remote, on: .unknown) }
        #expect(text?.contains("this simulator runs an unrecognised platform") == true)
        #expect(text?.contains("runs unknown") == false)
    }

    @Test("rotate and hinge are iOS only", arguments: [SimulatorPlatform.watchOS, .tvOS, .visionOS])
    func iOSOnly(platform: SimulatorPlatform) throws {
        #expect(message { try PlatformSupport.requireIOS(command: "rotate", on: platform) }?.hasPrefix("Rotate is only available on iOS simulators") == true)
        #expect(message { try PlatformSupport.requireIOS(command: "hinge", on: platform) }?.hasPrefix("Hinge is only available on iOS simulators") == true)
        try PlatformSupport.requireIOS(command: "rotate", on: .iOS)
        try PlatformSupport.requireIOS(command: "rotate", on: .unknown)
    }

    // MARK: Simulator lookup before the platform check

    private static let missingUDID = "00000000-0000-0000-0000-000000000000"
    private static let notFoundMessage = CLIError.simulatorNotFound(udid: missingUDID).message

    @Test("A missing simulator is reported as not found, not refused for its platform", arguments: [PlatformSupport.Input.remote, .touch, .button, .keyboard])
    func missingSimulatorFirst(input: PlatformSupport.Input) {
        #expect(message {
            try PlatformSupport.check(input, simulatorUDID: Self.missingUDID) { _ in nil }
        } == Self.notFoundMessage)
    }

    @Test("A found simulator with an unrecognised platform gets the platform refusal")
    func foundUnrecognisedSimulator() throws {
        var looked: [String] = []
        let text = message {
            try PlatformSupport.check(.remote, simulatorUDID: Self.missingUDID) { udid in
                looked.append(udid)
                return .unknown
            }
        }
        #expect(looked == [Self.missingUDID])
        #expect(text?.hasPrefix("Remote is only available on tvOS simulators (this simulator runs an unrecognised platform)") == true)
        // A found tvOS simulator passes and reports its platform.
        #expect(try PlatformSupport.check(.remote, simulatorUDID: Self.missingUDID) { _ in .tvOS } == .tvOS)
    }

    @Test("A failing lookup propagates its error instead of a platform refusal")
    func lookupErrorPropagates() {
        #expect(message {
            try PlatformSupport.check(.remote, simulatorUDID: Self.missingUDID) { _ in
                throw CLIError(errorDescription: "lookup failed")
            }
        } == "lookup failed")
    }

    @Test("button: a missing simulator is not found before the button is checked; an unrecognised one gets the iOS list")
    func buttonOrdering() {
        func refusal(_ button: ButtonType, _ lookup: (String) throws -> SimulatorPlatform?) -> String? {
            message { try button.validate(simulatorUDID: Self.missingUDID, lookup: lookup) }
        }
        #expect(refusal(.playPause) { _ in nil } == Self.notFoundMessage)
        #expect(refusal(.applePay) { _ in nil } == Self.notFoundMessage)
        #expect(refusal(.home) { _ in .unknown } == nil)
        let text = refusal(.playPause) { _ in .unknown }
        #expect(text == "Button 'play-pause' is not available on this simulator, which runs an unrecognised platform (treated as iOS). Valid buttons: apple-pay, home, lock, side-button, siri.")
    }
}

@Suite("Buttons by platform")
struct ButtonPlatformTests {
    @Test("Each platform's button list")
    func supportedLists() {
        #expect(ButtonType.supported(on: .iOS) == [.applePay, .home, .lock, .sideButton, .siri])
        #expect(ButtonType.supported(on: .unknown) == ButtonType.supported(on: .iOS))
        #expect(ButtonType.supported(on: .watchOS) == [.home, .sideButton, .lock, .siri])
        #expect(ButtonType.supported(on: .tvOS) == [.playPause, .volumeUp, .volumeDown])
        #expect(ButtonType.supported(on: .visionOS).isEmpty)
    }

    @Test("A supported button validates")
    func supportedValidates() throws {
        for platform in SimulatorPlatform.allCases where platform != .visionOS {
            for button in ButtonType.supported(on: platform) {
                try button.validate(for: platform)
            }
        }
    }

    private func refusal(_ button: ButtonType, on platform: SimulatorPlatform) -> String? {
        do {
            try button.validate(for: platform)
            return nil
        } catch let error as CLIError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test("Apple Pay on watchOS names the platform and the valid list")
    func applePayOnWatch() {
        #expect(refusal(.applePay, on: .watchOS) == "Button 'apple-pay' is not available on watchOS simulators. Valid buttons on watchOS: home, side-button, lock, siri.")
    }

    @Test("tvOS refusals point at axe remote")
    func homeOnTV() throws {
        let text = try #require(refusal(.home, on: .tvOS))
        #expect(text.contains("Valid buttons on tvOS: play-pause, volume-up, volume-down."))
        #expect(text.contains("axe remote"))
    }

    @Test("iOS keeps its five buttons and does not take the tvOS ones", arguments: [ButtonType.playPause, .volumeUp, .volumeDown])
    func tvButtonsOnIOS(button: ButtonType) {
        #expect(refusal(button, on: .iOS)?.contains("Valid buttons on iOS: apple-pay, home, lock, side-button, siri.") == true)
    }

    @Test("visionOS refuses buttons with the shared visionOS message")
    func visionButtons() {
        #expect(refusal(.home, on: .visionOS) == PlatformSupport.visionOSInputUnsupportedMessage)
    }

    @Test("The tvOS button names parse from the command line")
    func parsesTVOSButtonNames() throws {
        #expect(ButtonType(argument: "play-pause") == .playPause)
        #expect(ButtonType(argument: "volume-up") == .volumeUp)
        #expect(ButtonType(argument: "volume-down") == .volumeDown)
        #expect(ButtonType(argument: "playPause") == nil)
        #expect(try Button.parse(["play-pause", "--udid", "00000000-0000-0000-0000-000000000000"]).buttonType == .playPause)
    }

    @Test("The tvOS buttons map to IDB's consumer buttons")
    func hidButtons() {
        #expect(ButtonType.playPause.hidButton == .playPause)
        #expect(ButtonType.volumeUp.hidButton == .volumeUp)
        #expect(ButtonType.volumeDown.hidButton == .volumeDown)
        #expect(ButtonType.playPause.pressEvent(duration: nil, overDTUHID: true) == .shortButtonPress(.playPause))
    }

    @Test("button --help lists every button with its platform")
    func helpListsPlatforms() {
        let discussion = Button.configuration.discussion
        for button in ButtonType.allCases {
            #expect(discussion.contains(button.rawValue))
        }
        for platform in ["iOS/iPadOS", "watchOS", "tvOS", "visionOS"] {
            #expect(discussion.contains(platform))
        }
    }
}

@Suite("Remote command")
struct RemoteCommandTests {
    @Test(
        "Each action maps to IDB's remote event",
        arguments: [
            (RemoteAction.up, SimulatorHIDEvent.remoteButton(.up)),
            (.down, .remoteButton(.down)),
            (.left, .remoteButton(.left)),
            (.right, .remoteButton(.right)),
            (.select, .remoteButton(.select)),
            (.menu, .remoteButton(.menu)),
            (.playPause, .shortButtonPress(.playPause)),
        ]
    )
    func mapping(action: RemoteAction, expected: SimulatorHIDEvent) {
        #expect(action.pressEvent == expected)
        #expect(action.events(count: 1, delayMilliseconds: 500) == expected)
    }

    @Test("--count repeats the press with --delay milliseconds between presses")
    func repeated() {
        #expect(RemoteAction.down.events(count: 3, delayMilliseconds: 200) == .composite([
            .remoteButton(.down),
            .delay(0.2),
            .remoteButton(.down),
            .delay(0.2),
            .remoteButton(.down),
        ]))
        #expect(RemoteAction.right.events(count: 2, delayMilliseconds: 0) == .composite([
            .remoteButton(.right),
            .remoteButton(.right),
        ]))
    }

    @Test("Parses and validates its options")
    func parsing() throws {
        let remote = try Remote.parse(["right", "--count", "3", "--delay", "200", "--udid", "00000000-0000-0000-0000-000000000000"])
        #expect(remote.action == .right)
        #expect(remote.event == RemoteAction.right.events(count: 3, delayMilliseconds: 200))
        #expect(throws: (any Error).self) {
            _ = try Remote.parse(["right", "--count", "0", "--udid", "00000000-0000-0000-0000-000000000000"])
        }
        #expect(throws: (any Error).self) {
            _ = try Remote.parse(["right", "--delay", "-1", "--udid", "00000000-0000-0000-0000-000000000000"])
        }
        #expect(throws: (any Error).self) {
            _ = try Remote.parse(["home", "--udid", "00000000-0000-0000-0000-000000000000"])
        }
    }
}

@Suite("Coordinates and accessibility off iOS")
struct PlatformCoordinateTests {
    @Test("watchOS, tvOS and visionOS pass coordinates through", arguments: [SimulatorPlatform.watchOS, .tvOS, .visionOS])
    @MainActor
    func bypass(platform: SimulatorPlatform) throws {
        let mapping = try #require(OrientationAwareCoordinates.platformMapping(for: platform))
        guard case .passthrough = mapping else {
            Issue.record("Expected passthrough on \(platform.displayName)")
            return
        }
        let point = try OrientationAwareCoordinates.applyMapping(mapping, to: (x: 35, y: 140), logger: AxeLogger())
        #expect(point.x == 35 && point.y == 140)
    }

    @Test("iOS and unknown platforms keep orientation detection", arguments: [SimulatorPlatform.iOS, .unknown])
    @MainActor
    func detectionKept(platform: SimulatorPlatform) {
        #expect(OrientationAwareCoordinates.platformMapping(for: platform) == nil)
    }

    @Test("The accessibility bridge is restarted in the platform's launchd domain")
    @MainActor
    func bridgeDomains() async throws {
        #expect(AccessibilityFetcher.accessibilityBridgeDomains(for: .iOS) == ["user/foreground"])
        #expect(AccessibilityFetcher.accessibilityBridgeDomains(for: .visionOS) == ["user/foreground"])
        #expect(AccessibilityFetcher.accessibilityBridgeDomains(for: .watchOS) == ["system"])
        #expect(AccessibilityFetcher.accessibilityBridgeDomains(for: .tvOS) == ["user/foreground", "system"])

        var targets: [String] = []
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, arguments, _ in
                targets.append(arguments.last ?? "")
                return arguments.last?.hasPrefix("system/") == true ? 0 : 1
            },
            wait: { _ in }
        )
        try await AccessibilityFetcher.restartAccessibilityBridge(
            simulatorUDID: "00000000-0000-0000-0000-000000000000",
            platform: .watchOS,
            dependencies: dependencies
        )
        #expect(targets == ["system/com.apple.CoreSimulator.bridge"])

        targets = []
        try await AccessibilityFetcher.restartAccessibilityBridge(
            simulatorUDID: "00000000-0000-0000-0000-000000000000",
            platform: .tvOS,
            dependencies: dependencies
        )
        #expect(targets == ["user/foreground/com.apple.CoreSimulator.bridge", "system/com.apple.CoreSimulator.bridge"])
    }

    @Test("A selector miss over a childless tree off iOS reports the empty tree")
    func emptyTreeMessage() throws {
        let roots = try platformRoots(#"[{"type":"Application","AXUniqueId":"Carousel","frame":{"x":0,"y":0,"width":187,"height":223},"children":[]}]"#)
        let notFound = ElementResolutionError.notFound(kind: "--label", value: "Settings")

        let watch = AccessibilityTargetResolver.platformAwareError(notFound, roots: roots, platform: .watchOS)
        guard case .emptyTree(let kind, let value, let platform) = watch else {
            Issue.record("Expected emptyTree, got \(watch)")
            return
        }
        #expect(kind == "--label" && value == "Settings" && platform == .watchOS)
        let text = try #require(watch.errorDescription)
        #expect(text.contains("accessibility tree is empty on this watchOS simulator"))
        #expect(text.contains("describe-ui --point"))

        // iOS keeps the plain not-found message, and a populated tree is a real miss.
        guard case .notFound = AccessibilityTargetResolver.platformAwareError(notFound, roots: roots, platform: .iOS) else {
            Issue.record("iOS must keep notFound")
            return
        }
        let populated = try platformRoots(#"[{"type":"Application","children":[{"type":"Button","AXLabel":"Other"}]}]"#)
        guard case .notFound = AccessibilityTargetResolver.platformAwareError(notFound, roots: populated, platform: .watchOS) else {
            Issue.record("A populated watchOS tree must keep notFound")
            return
        }
    }

    @Test("The poller turns a final miss into the empty-tree error")
    @MainActor
    func pollerEmptyTree() async throws {
        let roots = try platformRoots(#"[{"type":"Application","frame":{"x":0,"y":0,"width":187,"height":223},"children":[]}]"#)
        do {
            _ = try await AccessibilityPoller.pollForResolution(
                query: .label("Settings"),
                waitTimeout: 0,
                pollInterval: 0.25,
                elementType: nil,
                platform: .watchOS,
                logger: AxeLogger()
            ) { roots }
            Issue.record("Expected a failure")
        } catch let error as ElementResolutionError {
            guard case .emptyTree = error else {
                Issue.record("Expected emptyTree, got \(error)")
                return
            }
        }
    }

    @Test("With --wait-timeout the poller refetches, then reports the empty tree")
    @MainActor
    func pollerEmptyTreeAfterWaiting() async throws {
        let roots = try platformRoots(#"[{"type":"Application","frame":{"x":0,"y":0,"width":187,"height":223},"children":[]}]"#)
        var fetches = 0
        do {
            _ = try await AccessibilityPoller.pollForResolution(
                query: .label("Settings"),
                waitTimeout: 0.3,
                pollInterval: 0.05,
                elementType: nil,
                platform: .watchOS,
                logger: AxeLogger()
            ) {
                fetches += 1
                return roots
            }
            Issue.record("Expected a failure")
        } catch let error as ElementResolutionError {
            guard case .emptyTree(_, _, let platform) = error else {
                Issue.record("Expected emptyTree, got \(error)")
                return
            }
            #expect(platform == .watchOS)
        }
        #expect(fetches > 1)
    }

    @Test("Every bridge domain is tried even when one times out, and the error lists each")
    @MainActor
    func bridgeRestartAllDomainsFail() async throws {
        var targets: [String] = []
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, arguments, _ in
                let target = arguments.last ?? ""
                targets.append(target)
                if target.hasPrefix("user/foreground/") {
                    throw CLIError(errorDescription: "timed out after 15 s")
                }
                return 113
            },
            wait: { _ in Issue.record("No wait after a failed restart") }
        )
        do {
            try await AccessibilityFetcher.restartAccessibilityBridge(
                simulatorUDID: "00000000-0000-0000-0000-000000000000",
                platform: .tvOS,
                dependencies: dependencies
            )
            Issue.record("Expected a failure")
        } catch let error as CLIError {
            #expect(error.message.contains("user/foreground: timed out after 15 s; system: launchctl exited with 113"))
            #expect(error.message.hasPrefix("AXe could not restart the accessibility service"))
        }
        #expect(targets == ["user/foreground/com.apple.CoreSimulator.bridge", "system/com.apple.CoreSimulator.bridge"])
    }

    @Test("A domain that times out does not stop a later domain from succeeding")
    @MainActor
    func bridgeRestartRecoversOnLaterDomain() async throws {
        var waited = false
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, arguments, _ in
                if arguments.last?.hasPrefix("user/foreground/") == true {
                    throw CLIError(errorDescription: "timed out")
                }
                return 0
            },
            wait: { _ in waited = true }
        )
        try await AccessibilityFetcher.restartAccessibilityBridge(
            simulatorUDID: "00000000-0000-0000-0000-000000000000",
            platform: .tvOS,
            dependencies: dependencies
        )
        #expect(waited)
    }
}

@Suite("Gesture presets off iOS")
struct PlatformGestureSizingTests {
    /// Apple Watch Series 12 (42mm): 374x446 pixels at 2x.
    private let watchScreen = TargetScreenInfo(widthPixels: 374, heightPixels: 446, scale: 2)

    @Test("IDB's screen info converts to points")
    func pointSize() throws {
        let size = try #require(Gesture.pointSize(screenInfo: watchScreen))
        #expect(size == (width: 187, height: 223))
        #expect(Gesture.pointSize(screenInfo: nil) == nil)
        #expect(Gesture.pointSize(screenInfo: TargetScreenInfo(widthPixels: 374, heightPixels: 446, scale: 0)) == nil)
    }

    @Test("Every preset stays inside the watch screen", arguments: GesturePreset.allCases)
    func presetsInsideWatch(preset: GesturePreset) throws {
        let gesture = try Gesture.parse([preset.rawValue, "--udid", "SIMULATOR_UDID"])
        let screen = try #require(Gesture.pointSize(screenInfo: watchScreen))
        #expect(gesture.screenSize(target: nil, mainScreen: screen) == (width: 187, height: 223))
        let coords = try gesture.coordinates(target: nil, mainScreen: screen)
        for x in [coords.startX, coords.endX] {
            #expect(x >= 0 && x <= 187)
        }
        for y in [coords.startY, coords.endY] {
            #expect(y >= 0 && y <= 223)
        }
        #expect(coords.startX != coords.endX || coords.startY != coords.endY)
    }

    @Test("scroll-up on the watch is centred and scrolls 60% of the height")
    func scrollUpOnWatch() throws {
        let gesture = try Gesture.parse(["scroll-up", "--udid", "SIMULATOR_UDID"])
        let coords = try gesture.coordinates(target: nil, mainScreen: (width: 187, height: 223))
        #expect(abs(coords.startX - 93.5) < 0.001 && abs(coords.endX - 93.5) < 0.001)
        #expect(abs(coords.startY - 178.4) < 0.001 && abs(coords.endY - 44.6) < 0.001)
    }

    @Test("--screen-width/--screen-height win over the main screen; iOS keeps 390x844 and its 200-point scroll")
    func optionsAndIOSDefault() throws {
        let gesture = try Gesture.parse(["scroll-up", "--screen-width", "200", "--udid", "SIMULATOR_UDID"])
        #expect(gesture.screenSize(target: nil, mainScreen: (width: 187, height: 223)) == (width: 200, height: 223))
        let plain = try Gesture.parse(["scroll-up", "--udid", "SIMULATOR_UDID"])
        #expect(plain.screenSize(target: nil) == (width: 390, height: 844))
        #expect(try plain.coordinates(target: nil) == (195, 522, 195, 322))
    }

    @Test("The main screen is only consulted off iOS and when an option is missing")
    @MainActor
    func mainScreenLookupScope() throws {
        let plain = try Gesture.parse(["scroll-up", "--udid", "SIMULATOR_UDID"])
        #expect(plain.mainScreenSize(platform: .iOS, simulatorUDID: "SIMULATOR_UDID", logger: AxeLogger()) == nil)
        #expect(plain.mainScreenSize(platform: .unknown, simulatorUDID: "SIMULATOR_UDID", logger: AxeLogger()) == nil)
        let sized = try Gesture.parse(["scroll-up", "--screen-width", "180", "--screen-height", "220", "--udid", "SIMULATOR_UDID"])
        #expect(sized.mainScreenSize(platform: .watchOS, simulatorUDID: "SIMULATOR_UDID", logger: AxeLogger()) == nil)
    }
}

@Suite("Batch remote step")
@MainActor
struct BatchRemoteStepTests {
    @Test("remote is a batch step kind")
    func stepKind() {
        #expect(BatchStepKind(rawValue: "remote") == .remote)
    }

    @Test("A remote step is parsed as the remote command and checks the simulator first")
    func parsesRemoteStep() async throws {
        let udid = "00000000-0000-0000-0000-000000000000"
        let context = BatchContext(simulatorUDID: udid, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
        do {
            _ = try await BatchStepParser.parseStepTokens(["remote", "up", "--count", "2"], globalUDID: udid, context: context, logger: AxeLogger())
            Issue.record("Expected the missing simulator to fail the step")
        } catch let error as CLIError {
            #expect(error.message == CLIError.simulatorNotFound(udid: udid).message)
        }
        // An invalid action is rejected by the remote command's own parser.
        await #expect(throws: (any Error).self) {
            _ = try await BatchStepParser.parseStepTokens(["remote", "home"], globalUDID: udid, context: context, logger: AxeLogger())
        }
    }
}

@Suite("Crown command")
struct CrownCommandTests {
    private static let udid = "00000000-0000-0000-0000-000000000000"

    private func message(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as CLIError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test("Defaults are IDB's: 10 steps 16 ms apart")
    func defaults() throws {
        let crown = try Crown.parse(["--delta", "50", "--udid", Self.udid])
        #expect(crown.rotation == CrownRotation(delta: 50, steps: 10, intervalMilliseconds: 16))
        #expect(CrownRotation.defaultSteps == 10)
        #expect(CrownRotation.defaultIntervalMilliseconds == 16)
    }

    @Test("Negative deltas parse with = and as a separate value", arguments: [["--delta=-50"], ["--delta", "-50"]])
    func negativeDelta(arguments: [String]) throws {
        let crown = try Crown.parse(arguments + ["--udid", Self.udid])
        #expect(crown.delta == -50)
    }

    @Test("Steps and interval map to the reports IDB sends")
    func eventMapping() throws {
        let crown = try Crown.parse(["--delta", "200", "--steps", "20", "--interval-ms", "8", "--udid", Self.udid])
        let rotation = crown.rotation
        #expect(rotation.steps == 20)
        #expect(rotation.deltaPerStep == 10)
        #expect(rotation.interval == .milliseconds(8))
        #expect(CrownRotation(delta: -50, steps: 10, intervalMilliseconds: 16).deltaPerStep == -5)
    }

    @Test(
        "Out-of-range options are refused",
        arguments: [
            ["--delta", "0"],
            ["--delta", "nan"],
            ["--delta", "20000"],
            ["--delta", "50", "--steps", "0"],
            ["--delta", "50", "--steps", "1001"],
            ["--delta", "50", "--interval-ms", "-1"],
            ["--delta", "50", "--interval-ms", "1001"],
            ["--steps", "10"],
        ]
    )
    func validation(arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try Crown.parse(arguments + ["--udid", Self.udid])
        }
    }

    @Test("crown is watchOS only", arguments: [SimulatorPlatform.iOS, .tvOS, .visionOS, .unknown])
    func watchOSOnly(platform: SimulatorPlatform) throws {
        let text = message { try PlatformSupport.check(.crown, on: platform) }
        #expect(text == "Crown is only available on watchOS simulators (this simulator runs \(platform.phrase))")
        try PlatformSupport.check(.crown, on: .watchOS)
    }

    @Test("A missing simulator is not found before the crown platform check")
    func missingSimulator() {
        #expect(message {
            try PlatformSupport.check(.crown, simulatorUDID: Self.udid) { _ in nil }
        } == CLIError.simulatorNotFound(udid: Self.udid).message)
    }

    @Test("crown --help documents negative deltas and the defaults")
    func help() {
        let discussion = Crown.configuration.discussion
        #expect(discussion.contains("--delta=-50"))
        #expect(discussion.contains("default 10 reports 16 ms apart"))
        #expect(discussion.contains("watchOS simulators only"))
    }
}

@Suite("Batch crown step")
@MainActor
struct BatchCrownStepTests {
    @Test("crown is a batch step kind")
    func stepKind() {
        #expect(BatchStepKind(rawValue: "crown") == .crown)
    }

    @Test("A crown step is parsed as the crown command and checks the simulator first")
    func parsesCrownStep() async throws {
        let udid = "00000000-0000-0000-0000-000000000000"
        let context = BatchContext(simulatorUDID: udid, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
        do {
            _ = try await BatchStepParser.parseStepTokens(["crown", "--delta=-50"], globalUDID: udid, context: context, logger: AxeLogger())
            Issue.record("Expected the missing simulator to fail the step")
        } catch let error as CLIError {
            #expect(error.message == CLIError.simulatorNotFound(udid: udid).message)
        }
        await #expect(throws: (any Error).self) {
            _ = try await BatchStepParser.parseStepTokens(["crown", "--delta", "0"], globalUDID: udid, context: context, logger: AxeLogger())
        }
    }
}

@Suite("Batch platform check before any step runs")
struct BatchPlatformPreflightTests {
    private func refusal(_ steps: [String], on platform: SimulatorPlatform) -> String? {
        do {
            try Batch.checkSteps(steps, udid: "SIMULATOR_UDID", on: platform)
            return nil
        } catch let error as CLIError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test("A tvOS touch step after a remote step refuses the batch, naming the step")
    func tvOSTouchAfterRemote() throws {
        let text = try #require(refusal(["remote up", "tap -x 10 -y 10", "button home"], on: .tvOS))
        #expect(text.hasPrefix("Step 2 failed: [tap]\nTouch input is not available on tvOS simulators; use `axe remote`"))
        #expect(text.contains("No step was run"))
    }

    @Test(
        "Each step kind gets its command's platform rule",
        arguments: [
            ("crown --delta 50", SimulatorPlatform.iOS, "Crown is only available on watchOS simulators"),
            ("crown --delta=-50", .tvOS, "Crown is only available on watchOS simulators"),
            ("remote down", .watchOS, "Remote is only available on tvOS simulators"),
            ("rotate landscape", .watchOS, "Rotate is only available on iOS simulators"),
            ("hinge open", .tvOS, "Hinge is only available on iOS simulators"),
            ("button home", .tvOS, "Button 'home' is not available on tvOS simulators"),
            ("button apple-pay", .watchOS, "Button 'apple-pay' is not available on watchOS simulators"),
            ("swipe --start-x 1 --start-y 1 --end-x 2 --end-y 2", .tvOS, "Touch input is not available on tvOS simulators"),
            ("gesture scroll-up", .tvOS, "Touch input is not available on tvOS simulators"),
            ("touch -x 1 -y 1 --down", .tvOS, "Touch input is not available on tvOS simulators"),
            ("type hello", .visionOS, "Input is not supported on visionOS simulators"),
            ("key 40", .visionOS, "Input is not supported on visionOS simulators"),
        ]
    )
    func rules(step: String, platform: SimulatorPlatform, prefix: String) throws {
        let text = try #require(refusal(["sleep 0", step], on: platform))
        #expect(text.hasPrefix("Step 2 failed: [\(step.split(separator: " ")[0])]\n\(prefix)"))
    }

    @Test("Steps the platform takes and that parse pass")
    func accepted() {
        #expect(refusal(["remote up", "type abc", "key-sequence --keycodes 4,5", "button play-pause", "sleep 1"], on: .tvOS) == nil)
        #expect(refusal(["crown --delta 50", "tap --label Settings", "button home", "swipe --start-x 1 --start-y 1 --end-x 2 --end-y 2"], on: .watchOS) == nil)
        #expect(refusal(["tap -x 1 -y 1", "rotate landscape", "hinge open", "button apple-pay", "key-combo --modifiers 227 --key 4"], on: .iOS) == nil)
        #expect(refusal(["button --duration 1 play-pause"], on: .tvOS) == nil)
    }

    @Test(
        "Malformed steps fail the batch before any step runs",
        arguments: [
            ("unknown-step", "unknown-step", "Unsupported batch step 'unknown-step'."),
            ("type 'unterminated", "<unparsed>", ""),
            ("button not-a-button", "button", ""),
            ("crown --steps 0 --delta 50", "crown", "--steps must be between 1 and 1000."),
            ("crown --delta 0", "crown", "--delta must be a non-zero number"),
            ("remote up --count 0", "remote", "--count must be between 1 and"),
            ("tap --label Settings --udid OTHER", "tap", "Per-step --udid is not supported"),
            ("sleep -1", "sleep", "Sleep step requires a non-negative number of seconds."),
            ("hinge sweep", "hinge", "Hinge step format"),
            ("rotate sideways", "rotate", "Rotate step format"),
            ("swipe --start-x 1 --start-y 1 --end-x 1 --end-y 1", "swipe", ""),
        ]
    )
    func malformed(step: String, name: String, message: String) throws {
        let platform: SimulatorPlatform = step.hasPrefix("crown") ? .watchOS : step.hasPrefix("remote") ? .tvOS : .iOS
        let text = try #require(refusal(["sleep 0", step, "tap -x 1 -y 1"], on: platform))
        #expect(text.hasPrefix("Step 2 failed: [\(name)]\n\(message)"))
        #expect(text.hasSuffix("No step was run: every step is parsed and checked against the simulator's platform before the batch starts."))
    }

    @Test("A button refused by the platform is found wherever its name sits among the options")
    func buttonAfterOptions() throws {
        let text = try #require(refusal(["remote up", "button --duration 1 home"], on: .tvOS))
        #expect(text.hasPrefix("Step 2 failed: [button]\nButton 'home' is not available on tvOS simulators"))
        let applePay = try #require(refusal(["button --duration 1 apple-pay"], on: .watchOS))
        #expect(applePay.hasPrefix("Step 1 failed: [button]\nButton 'apple-pay' is not available on watchOS simulators"))
    }

    @Test("The first refused step is reported")
    func firstRefusal() {
        #expect(refusal(["tap -x 1 -y 1", "crown --delta 5"], on: .tvOS)?.hasPrefix("Step 1 failed: [tap]") == true)
        #expect(refusal(["crown --delta 5", "crown --steps 0 --delta 5", "tap -x 1 -y 1"], on: .tvOS)?.hasPrefix("Step 1 failed: [crown]") == true)
    }

    @Test("Batch checks the steps before opening a session, and not with --continue-on-error")
    func preflightWiring() async throws {
        var lookups = 0
        let steps = ["remote up", "button --duration 1 home"]
        await #expect(throws: CLIError.self) {
            try await Batch.preflight(steps, udid: "SIMULATOR_UDID", continueOnError: false) {
                lookups += 1
                return .tvOS
            }
        }
        #expect(lookups == 1)
        try await Batch.preflight(steps, udid: "SIMULATOR_UDID", continueOnError: true) {
            lookups += 1
            return .tvOS
        }
        #expect(lookups == 1)
        try await Batch.preflight(["remote up", "button play-pause"], udid: "SIMULATOR_UDID", continueOnError: false) { .tvOS }
    }

    @Test("Batch help documents the up-front parse")
    func help() {
        #expect(Batch.configuration.discussion.contains("every step's arguments are parsed"))
    }
}

@Suite("Batch runner cache invalidation")
@MainActor
struct BatchRunnerCacheTests {
    private func seededContext() throws -> BatchContext {
        let context = BatchContext(simulatorUDID: "SIMULATOR_UDID", axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
        let json = #"[{"type":"Application","frame":{"x":0,"y":0,"width":10,"height":10},"children":[]}]"#
        context.cachedRoots = try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
        return context
    }

    @Test("A crown step drops the perBatch accessibility snapshot")
    func crownDropsSnapshot() throws {
        let context = try seededContext()
        #expect(context.cachedRoots != nil)
        let crown = BatchPrimitive.crownRotation(CrownRotation(delta: 50, steps: 10, intervalMilliseconds: 16))
        #expect(crown.invalidatesAccessibilitySnapshot)
        #expect(!crown.invalidatesDisplayState)
        BatchPlanRunner.invalidateCaches(after: crown, context: context)
        #expect(context.cachedRoots == nil)
    }

    @Test("Hinge and rotate steps drop the snapshot and display state; touch, key and button steps keep the snapshot")
    func otherPrimitives() throws {
        let rotate = BatchPrimitive.deviceState(.rotate(.landscape))
        #expect(rotate.invalidatesAccessibilitySnapshot)
        #expect(rotate.invalidatesDisplayState)

        let kept: [BatchPrimitive] = [
            .hidMergeable(.tapAt(x: 1, y: 1)),
            .hidBarrier(.shortKeyPress(4)),
            .hostSleep(0),
            .physicalTap(point: (x: 1, y: 1), preDelay: nil, postDelay: nil),
            .buttonPress(.home, duration: nil),
        ]
        let context = try seededContext()
        for primitive in kept {
            #expect(!primitive.invalidatesAccessibilitySnapshot)
            #expect(!primitive.invalidatesDisplayState)
            BatchPlanRunner.invalidateCaches(after: primitive, context: context)
        }
        #expect(context.cachedRoots != nil)
    }
}

@Suite("Crown errors")
struct CrownErrorTests {
    @Test("IDB's missing DTUHID crown service and missing XPC symbols map to the Xcode 27 message")
    func dtuhidErrors() throws {
        let notVended = try #require(CrownRotation.userFacingError(for: SimulatorHIDError.dtuhidServiceNotVended(name: "com.apple.dtuhidd.scroll")) as? CLIError)
        #expect(notVended.message.contains("(com.apple.dtuhidd.scroll)"))
        #expect(notVended.message.contains("Xcode 27 or later"))
        #expect(notVended.message.hasSuffix("No rotation was sent."))

        let noSymbols = try #require(CrownRotation.userFacingError(for: SimulatorHIDError.dtuhidXPCSymbolsUnavailable) as? CLIError)
        #expect(noSymbols.message.contains("Xcode 27 or later"))
        #expect(noSymbols.message.hasSuffix("No rotation was sent."))

        let other = CrownRotation.userFacingError(for: SimulatorHIDError.dtuhidConnectionFailed)
        #expect(other is SimulatorHIDError)
        #expect(!(other is CLIError))
    }
}
