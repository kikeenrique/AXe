import ArgumentParser
import Foundation

struct Posture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the hinge angle, the active display, and display orientation and size.",
        discussion: """
        Works on any simulator. hingeAngle is null on simulators without a hinge. sizePoints is the
        active interface size in points (native size over point scale, swapped for rot90/rot270).
        The hinge angle, display activity, rotation and size come from the simulator through
        IDB; display IDs, backlight and device orientation from `xcrun devicectl device info
        displays`. When devicectl fails, AXe prints the displays IDB reports with a warning on
        stderr, and the backlight and device orientation as unknown.
        """
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Flag(name: .customLong("json"), help: "Print the posture as JSON.")
    var json: Bool = false

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let simulator = try await FoldableDevice.bootedSimulator(udid: simulatorUDID, logger: logger)
        let posture = try await FoldableDevice.posture(simulator: simulator, logger: logger)
        print(json ? try posture.jsonString() : posture.textSummary)
    }
}
