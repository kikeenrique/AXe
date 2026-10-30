import Foundation
import FBControlCore

/// AXe's logger. Upstream `CompositeLogger` is `final`, so AXe wraps one instead of subclassing it.
/// Every stored property is immutable and `Sendable`, so the wrapper is `Sendable` as well.
final class AxeLogger: ControlCoreLogger, Sendable {
    private let composite: CompositeLogger

    init(loggers: [ControlCoreLogger]) {
        self.composite = CompositeLogger(loggers: loggers)
    }

    convenience init(debugLogging: Bool = false, writeToStdErr: Bool = true) {
        let systemLogger = ControlCoreGlobalConfiguration.systemLogger(
            writingToStderr: writeToStdErr,
            debugLogging: debugLogging
        )
        self.init(loggers: [systemLogger])
    }

    convenience init() {
        self.init(debugLogging: false, writeToStdErr: false)
    }

    var loggers: [ControlCoreLogger] { composite.loggers }

    func makeDefault() {
        ControlCoreGlobalConfiguration.defaultLogger = self
    }

    func warning() -> ControlCoreLogger {
        return composite.debug()
    }

    // MARK: ControlCoreLogger

    @discardableResult
    func log(_ message: String) -> ControlCoreLogger {
        composite.log(message)
        return self
    }

    func info() -> ControlCoreLogger { composite.info() }
    func debug() -> ControlCoreLogger { composite.debug() }
    func error() -> ControlCoreLogger { composite.error() }
    func withName(_ name: String) -> ControlCoreLogger { composite.withName(name) }
    func withDateFormatEnabled(_ enabled: Bool) -> ControlCoreLogger { composite.withDateFormatEnabled(enabled) }
    var name: String? { composite.name }
    var level: ControlCoreLogLevel { composite.level }
}
