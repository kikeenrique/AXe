import Foundation

// MARK: - Error Types
protocol UserFacingError: Error, CustomStringConvertible {
    var userFacingDescription: String { get }
}

extension UserFacingError {
    var description: String {
        userFacingDescription
    }
}

struct CLIError: LocalizedError, UserFacingError {
    let message: String

    init(errorDescription: String) {
        self.message = errorDescription
    }

    static func simulatorNotFound(udid: String) -> CLIError {
        CLIError(
            errorDescription: "No simulator with UDID \(udid) was found. Run `axe list-simulators` to see available simulators."
        )
    }

    // `LocalizedError` requires `String?`; a non-optional stored property would not satisfy it and
    // `localizedDescription` would fall back to Foundation's generic text.
    var errorDescription: String? {
        message
    }

    var userFacingDescription: String {
        message
    }
}
