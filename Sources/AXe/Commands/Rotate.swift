import ArgumentParser
import Foundation

struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rotate the interface of the active display.",
        discussion: """
        Orientations name the interface, not the device. On foldable simulators AXe sends Device
        Hub's orientation event, trying device orientations until the active display reports the
        requested rotation (portrait rot0, landscape rot90, portrait-upside-down rot180,
        landscape-flipped rot270), and restore the starting orientation when none matches. Other
        simulators use `xcrun devicectl device orientation set` (landscape is device landscapeRight);
        AXe checks that the device took the orientation and warns when the active display does not
        rotate, for example on a home screen that stays portrait.

        Example:
          axe rotate landscape --udid SIMULATOR_UDID
        """
    )

    @Argument(help: "Interface orientation: portrait, landscape, portrait-upside-down, or landscape-flipped.")
    var orientation: InterfaceOrientation

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Flag(name: .customLong("json"), help: "Print the resulting posture as JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let simulator = try await FoldableDevice.bootedSimulator(udid: simulatorUDID, logger: logger)
        let warning = try await FoldableDevice.perform(.rotate(orientation), simulator: simulator, logger: logger)
        if let warning {
            print("Warning: \(warning)", to: &standardError)
        }
        let posture = try await FoldableDevice.posture(simulator: simulator, logger: logger)
        if json {
            print(try posture.jsonString())
        } else {
            if warning == nil {
                print("Rotated to \(orientation.rawValue)")
            }
            print(posture.textSummary)
        }
    }
}
