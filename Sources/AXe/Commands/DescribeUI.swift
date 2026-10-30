import ArgumentParser
import Foundation

struct DescribeUI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Describes the UI hierarchy of a booted simulator using accessibility information."
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Option(
        name: .customLong("point"),
        help: ArgumentHelp(
            "Describe only the accessibility element at screen coordinates x,y. On a foldable, x,y are interface points of the active display, as `axe screenshot` shows it.",
            valueName: "x,y"
        )
    )
    var point: String?

    @Flag(
        name: .customLong("all-displays"),
        help: "On a foldable with the inner display active, print the active display's tree as the simulator reports it, without AXe's window filtering and frame conversion (home-screen frames stay in the panel's native portrait points). With --point, use the simulator's hit test, which also takes interface points of the active display."
    )
    var allDisplays = false

    func validate() throws {
        _ = try parsedPoint()
    }

    func run() async throws {
        let logger = AxeLogger()
        try await performGlobalSetup(logger: logger)

        let jsonData = try await AccessibilityFetcher.fetchDescribeUIJSONData(
            for: simulatorUDID,
            point: try parsedPoint(),
            allDisplays: allDisplays,
            logger: logger
        )
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw CLIError(errorDescription: "Failed to convert accessibility info to JSON string.")
        }
        print(jsonString)
    }

    private func parsedPoint() throws -> AccessibilityPoint? {
        guard let point else {
            return nil
        }

        let coordinates = point
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard coordinates.count == 2,
              let x = Double(coordinates[0]),
              let y = Double(coordinates[1]),
              x.isFinite,
              y.isFinite,
              x >= 0,
              y >= 0
        else {
            throw ValidationError("--point must be in the form x,y using non-negative numbers.")
        }

        return AccessibilityPoint(x: x, y: y)
    }
}
