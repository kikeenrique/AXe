import FBSimulatorControl
import Foundation
import Testing
@testable import AXe

@Suite("IDB bridge resources")
struct IDBBridgeResourcesTests {
    private let bridge = IDBBridgeResources.bridgeName

    @Test("AXE_IDB_BRIDGE_DIR wins over every other location")
    func environmentWins() throws {
        let directory = try IDBBridgeResources.resolveDirectory(
            environment: [IDBBridgeResources.environmentKey: "/opt/bridge"],
            executablePath: "/checkout/.build/debug/axe",
            fileExists: { _ in true }
        )

        #expect(directory == "/opt/bridge")
    }

    @Test("A relative AXE_IDB_BRIDGE_DIR resolves against the current directory")
    func relativeEnvironment() throws {
        let directory = try IDBBridgeResources.resolveDirectory(
            environment: [IDBBridgeResources.environmentKey: "build_products/idb/bridge"],
            executablePath: nil,
            currentDirectory: "/checkout",
            fileExists: { $0 == "/checkout/build_products/idb/bridge/\(bridge)" }
        )

        #expect(directory == "/checkout/build_products/idb/bridge")
    }

    @Test("AXE_IDB_BRIDGE_DIR without the helper is a clear error, not a fallback")
    func environmentWithoutHelper() {
        do {
            _ = try IDBBridgeResources.resolveDirectory(
                environment: [IDBBridgeResources.environmentKey: "/opt/empty"],
                executablePath: "/usr/local/libexec/axe",
                fileExists: { $0 == "/usr/local/libexec/Resources/\(bridge)" }
            )
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("AXE_IDB_BRIDGE_DIR"))
            #expect(error.localizedDescription.contains("/opt/empty does not contain \(bridge)"))
        }
    }

    @Test("Resources beside the executable is used when it holds the bridge")
    func besideExecutable() throws {
        let directory = try IDBBridgeResources.resolveDirectory(
            environment: [:],
            executablePath: "/usr/local/libexec/axe",
            fileExists: { $0 == "/usr/local/libexec/Resources/\(bridge)" }
        )

        #expect(directory == "/usr/local/libexec/Resources")
    }

    @Test("A swift build binary finds the checkout's build_products bridge")
    func checkoutBridge() throws {
        let existing: Set<String> = [
            "/checkout/Package.swift",
            "/checkout/build_products/idb/bridge/\(bridge)",
        ]
        let directory = try IDBBridgeResources.resolveDirectory(
            environment: [:],
            executablePath: "/checkout/.build/arm64-apple-macosx/debug/axe",
            fileExists: { existing.contains($0) }
        )

        #expect(directory == "/checkout/build_products/idb/bridge")
    }

    @Test("Nothing found leaves IDB's own lookup in place")
    func nothingFound() throws {
        let directory = try IDBBridgeResources.resolveDirectory(
            environment: [:],
            executablePath: "/checkout/.build/debug/axe",
            fileExists: { $0 == "/checkout/Package.swift" }
        )

        #expect(directory == nil)
    }
}

@Suite("Button events")
struct ButtonEventTests {
    @Test("Apple Pay over DTUHID is two side-button presses")
    func applePayOverDTUHID() {
        let event = ButtonType.applePay.pressEvent(duration: nil, overDTUHID: true)

        #expect(event == .composite([
            .shortButtonPress(.sideButton),
            .delay(ButtonType.applePayPressGap),
            .shortButtonPress(.sideButton),
        ]))
    }

    @Test("A held Apple Pay press splits the hold between the two side-button presses")
    func applePayHeldOverDTUHID() {
        let event = ButtonType.applePay.pressEvent(duration: 2, overDTUHID: true)
        let press = SimulatorHIDEvent.composite([
            .button(direction: .down, button: .sideButton),
            .delay(1),
            .button(direction: .up, button: .sideButton),
        ])

        #expect(event == .composite([press, .delay(ButtonType.applePayPressGap), press]))
    }

    @Test("Other buttons, and Apple Pay over Indigo, are single presses")
    func singlePresses() {
        #expect(ButtonType.home.pressEvent(duration: nil, overDTUHID: true) == .shortButtonPress(.homeButton))
        #expect(ButtonType.applePay.pressEvent(duration: nil, overDTUHID: false) == .shortButtonPress(.applePay))
    }
}

@Suite("HID transport selection")
struct HIDTransportSelectionTests {
    @Test(
        "DTUHID ships from CoreSimulator 1155.4, compared numerically",
        arguments: [
            (String?.none, false),
            ("999.9", false),
            ("1155.3", false),
            ("1155.4", true),
            ("1155.10", true),
            ("1160", true),
        ]
    )
    func shipsDTUHID(version: String?, expected: Bool) {
        #expect(HIDBroker.shipsDTUHID(coreSimulatorVersion: version) == expected)
    }
}

@Suite("IDB touch rotation decision")
@MainActor
struct IDBTouchRotationTests {
    private let portraitSize = (width: 402.0, height: 874.0)

    private func isPassthrough(_ mapping: CoordinateMapping) -> Bool {
        if case .passthrough = mapping { return true }
        return false
    }

    private func rotation(_ mapping: CoordinateMapping) -> SimulatorOrientation? {
        if case .rotation(let orientation, _) = mapping { return orientation }
        return nil
    }

    // `IDBTouchRouting.activeDisplay` is what `activeGeometry()` yields for an identified display
    // (iOS 27) and for the sole display of a legacy report (Xcode 27.x driving iOS 26): IDB then
    // unrotates interface points itself, so AXe must pass them through.
    @Test(
        "IDB routes to the active display (identified or legacy report): AXe passes rotated points through",
        arguments: [SimulatorOrientation.landscape, .landscapeFlipped, .portraitUpsideDown]
    )
    func idbRotates(orientation: SimulatorOrientation) {
        let mapping = OrientationAwareCoordinates.rotatedMapping(
            orientation,
            portraitSize: portraitSize,
            routing: .activeDisplay
        )

        #expect(isPassthrough(mapping))
    }

    @Test(
        "No usable display report: IDB sends raw points and AXe rotates",
        arguments: [SimulatorOrientation.landscape, .landscapeFlipped, .portraitUpsideDown]
    )
    func axeRotates(orientation: SimulatorOrientation) {
        let mapping = OrientationAwareCoordinates.rotatedMapping(
            orientation,
            portraitSize: portraitSize,
            routing: .rawPoints(reason: "display report unreadable")
        )

        #expect(rotation(mapping) == orientation)
    }
}

@Suite("Batch display-change failure")
struct BatchDisplayChangeTests {
    @Test("A display change during a step names the cause and how to recover")
    func displayChanged() {
        for error in [SimulatorDisplayError.changed, .transitioning] {
            let message = Batch.stepFailureMessage(for: error)

            #expect(message.contains("display changed"))
            #expect(message.contains("Re-run the batch from this step"))
        }
    }

    @Test("Other display errors keep their own description")
    func otherDisplayError() {
        let error = SimulatorDisplayError.noActiveIntegratedDisplay

        #expect(Batch.stepFailureMessage(for: error) == error.localizedDescription)
    }
}
