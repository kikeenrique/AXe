import Foundation
import FBControlCore
import FBSimulatorControl

@MainActor
func performGlobalSetup(logger: AxeLogger) async throws {
    logger.info().log("Performing global setup...")

    // Check Xcode availability. IDB resolves the developer directory from the xcode-select link
    // (falling back to `xcode-select -p`); it does not read DEVELOPER_DIR.
    logger.info().log("Checking Xcode availability...")
    let xcodePath = XcodeConfiguration.developerDirectory
    if xcodePath.isEmpty {
        let errorMessage = "AXe could not find an active Xcode installation. Select Xcode with `xcode-select`, then try again."
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage)
    }
    logger.info().log("Xcode is available at: \(xcodePath)")

    try IDBBridgeResources.configure(logger: logger)

    // Load the essential private frameworks now for an early, readable error. The bootstrap and the
    // HID, display and accessibility clients load what else they need on first use.
    logger.info().log("Loading essential private frameworks...")
    do {
        try SimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
        logger.info().log("Successfully loaded essential private frameworks.")
    } catch {
        let errorMessage = "AXe could not load simulator support from the selected Xcode installation: \(error.localizedDescription)"
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage)
    }
    logger.info().log("Global setup complete.")
}
