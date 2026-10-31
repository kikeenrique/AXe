import ArgumentParser
import Foundation

struct DescribeUI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Describes the UI hierarchy of a booted simulator using accessibility information.",
        discussion: """
        Each element carries `focused`: true on the element that has focus (on tvOS, the item the Siri Remote moves), false or null elsewhere. --focused prints only that element.

        Examples:
          axe describe-ui --udid SIMULATOR_UDID
          axe describe-ui --point 100,200 --udid SIMULATOR_UDID
          axe describe-ui --focused --udid SIMULATOR_UDID
        """
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

    @Flag(
        name: .customLong("focused"),
        help: "Print only the focused element (the one whose `focused` is true, the deepest if several are), without its children. Fails with \"No focused element\" when no element reports focus. On tvOS this is the item the Siri Remote moves; use it after `axe remote`."
    )
    var focused = false

    func validate() throws {
        _ = try parsedPoint()
        if focused, point != nil {
            throw ValidationError("--focused cannot be combined with --point.")
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await performGlobalSetup(logger: logger)

        let jsonData = try await AccessibilityFetcher.fetchDescribeUIJSONData(
            for: simulatorUDID,
            point: try parsedPoint(),
            allDisplays: allDisplays,
            focusedOnly: focused,
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
