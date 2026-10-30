import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

extension AsyncParsableCommand {
    func setup(logger: AxeLogger) async throws {
        // Check Xcode availability. IDB resolves the developer directory from the xcode-select
        // link (falling back to `xcode-select -p`); it does not read DEVELOPER_DIR.
        if XcodeConfiguration.developerDirectory.isEmpty {
            logger.error().log("No active Xcode developer directory was found")
            throw CLIError(
                errorDescription: "AXe could not find an active Xcode installation. Select Xcode with `xcode-select`, then try again."
            )
        }

        // Load essential frameworks
        do {
            try SimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
        } catch {
            logger.error().log("Failed to load simulator support: \(error.localizedDescription)")
            throw CLIError(
                errorDescription: "AXe could not load simulator support from the selected Xcode installation. Confirm Xcode 26 or later is selected and try again."
            )
        }
    }
}
