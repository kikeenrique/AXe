import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct ListSimulators: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lists all available simulators."
    )

    func run() async throws {
        let logger = AxeLogger()

        try await performGlobalSetup(logger: logger)

        let simulators = try await SimulatorSession.allSimulators(logger: logger)
        simulators.forEach { print($0.description) }
    }
}
