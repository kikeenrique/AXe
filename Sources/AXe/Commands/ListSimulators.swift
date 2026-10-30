import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct ListSimulators: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lists all available simulators.",
        discussion: """
        Each line is: UDID | name | state | model | OS '<runtime>' | Platform '<platform>'.
        The platform is iOS (iPhone and iPad), watchOS, tvOS, visionOS or unknown, and decides
        which input commands the simulator accepts.
        """
    )

    func run() async throws {
        let logger = AxeLogger()

        try await performGlobalSetup(logger: logger)

        let simulators = try await SimulatorSession.allSimulators(logger: logger)
        simulators.forEach { print(Self.line(description: $0.description, platform: $0.platform)) }
    }

    /// IDB's one-line description (unchanged, so existing parsers keep working) followed by the
    /// platform field. IDB's description ends with a space after the OS field.
    static func line(description: String, platform: SimulatorPlatform) -> String {
        let base = description.hasSuffix(" ") ? description : description + " "
        return "\(base)| Platform '\(platform.displayName)'"
    }
}
