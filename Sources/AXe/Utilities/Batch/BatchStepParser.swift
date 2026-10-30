import ArgumentParser
import Foundation

enum BatchStepKind: String {
    case tap
    case swipe
    case gesture
    case touch
    case type
    case button
    case key
    case keySequence = "key-sequence"
    case keyCombo = "key-combo"
    case remote
    case sleep
    case hinge
    case rotate
}

@MainActor
struct BatchStepParser {
    static func parseStepTokens(
        _ tokens: [String],
        globalUDID: String,
        context: BatchContext,
        logger: AxeLogger
    ) async throws -> [BatchPrimitive] {
        guard let firstToken = tokens.first else {
            return []
        }

        guard let kind = BatchStepKind(rawValue: firstToken) else {
            throw ValidationError("Unsupported batch step '\(firstToken)'.")
        }

        if kind == .sleep {
            return try parseSleep(tokens)
        }

        let stepArguments = Array(tokens.dropFirst())
        try ensureNoPerStepUDID(stepArguments)
        let arguments = stepArguments + ["--udid", globalUDID]

        switch kind {
        case .tap:
            return try await parseCommand(Tap.self, arguments: arguments, context: context, logger: logger)
        case .swipe:
            return try await parseCommand(Swipe.self, arguments: arguments, context: context, logger: logger)
        case .gesture:
            return try await parseCommand(Gesture.self, arguments: arguments, context: context, logger: logger)
        case .touch:
            return try await parseCommand(Touch.self, arguments: arguments, context: context, logger: logger)
        case .type:
            return try await parseCommand(Type.self, arguments: arguments, context: context, logger: logger)
        case .button:
            return try await parseCommand(Button.self, arguments: arguments, context: context, logger: logger)
        case .key:
            return try await parseCommand(Key.self, arguments: arguments, context: context, logger: logger)
        case .keySequence:
            return try await parseCommand(KeySequence.self, arguments: arguments, context: context, logger: logger)
        case .keyCombo:
            return try await parseCommand(KeyCombo.self, arguments: arguments, context: context, logger: logger)
        case .remote:
            return try await parseCommand(Remote.self, arguments: arguments, context: context, logger: logger)
        case .hinge:
            return [.deviceState(try parseHinge(arguments))]
        case .rotate:
            return [.deviceState(try parseRotate(arguments))]
        case .sleep:
            return []
        }
    }

    static let hingeStepFormat = "Hinge step format: hinge <set <degrees>|open|close|half> [--duration <s>] [--no-wait]"

    /// Parses `hinge set|open|close|half` with the `axe hinge` parser; `sweep` and `get` are not steps.
    private static func parseHinge(_ arguments: [String]) throws -> DeviceStateAction {
        let parsed: ParsableCommand
        do {
            parsed = try Hinge.parseAsRoot(arguments)
        } catch {
            throw ValidationError("\(hingeStepFormat). \(Hinge.message(for: error))")
        }
        guard let moving = parsed as? any HingeMoving, !(parsed is Hinge.Sweep) else {
            throw ValidationError(hingeStepFormat)
        }
        if moving.options.json {
            throw ValidationError("--json is not supported in batch hinge steps.")
        }
        return moving.action
    }

    static let rotateStepFormat = "Rotate step format: rotate <portrait|landscape|portrait-upside-down|landscape-flipped>"

    private static func parseRotate(_ arguments: [String]) throws -> DeviceStateAction {
        let rotate: Rotate
        do {
            rotate = try Rotate.parse(arguments)
        } catch {
            throw ValidationError("\(rotateStepFormat). \(Rotate.message(for: error))")
        }
        if rotate.json {
            throw ValidationError("--json is not supported in batch rotate steps.")
        }
        return .rotate(rotate.orientation)
    }

    private static func parseCommand<C: AsyncParsableCommand & BatchConvertible>(
        _ type: C.Type,
        arguments: [String],
        context: BatchContext,
        logger: AxeLogger
    ) async throws -> [BatchPrimitive] {
        guard var parsed = try C.parseAsRoot(arguments) as? C else {
            throw CLIError(errorDescription: "Failed to parse batch step arguments: \(arguments.joined(separator: " "))")
        }
        try parsed.validate()
        return try await parsed.toBatchPrimitives(context: context, logger: logger)
    }

    private static func ensureNoPerStepUDID(_ args: [String]) throws {
        if args.contains(where: { $0 == "--udid" || $0.hasPrefix("--udid=") }) {
            throw ValidationError("Per-step --udid is not supported in batch steps. Use batch-level --udid.")
        }
    }

    private static func parseSleep(_ tokens: [String]) throws -> [BatchPrimitive] {
        guard tokens.count == 2 else {
            throw ValidationError("Sleep step format: sleep <seconds>")
        }
        guard let seconds = Double(tokens[1]), seconds >= 0 else {
            throw ValidationError("Sleep step requires a non-negative number of seconds.")
        }
        return [.hostSleep(seconds)]
    }
}
