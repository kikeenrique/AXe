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
    case crown
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
        case .crown:
            return try await parseCommand(Crown.self, arguments: arguments, context: context, logger: logger)
        case .hinge:
            return [.deviceState(try parseHinge(arguments))]
        case .rotate:
            return [.deviceState(try parseRotate(arguments))]
        case .sleep:
            return []
        }
    }

    /// Parses a step's arguments with its command's parser and throws the error the step would give
    /// for them, then throws the refusal its command gives on `platform`, with the same checks the
    /// step runs itself (`PlatformSupport`, `ButtonType.validate(for:)`). `Batch` checks every step
    /// with this before it runs any, so a malformed or refused step does not leave earlier steps
    /// applied.
    ///
    /// Pure: nothing is sent and the simulator is not queried. Errors that depend on simulator
    /// state (an element that is not on screen, a step file that cannot be read) still surface when
    /// the step runs.
    nonisolated static func preflight(ofStep tokens: [String], globalUDID: String, on platform: SimulatorPlatform) throws {
        guard let first = tokens.first else {
            return
        }
        guard let kind = BatchStepKind(rawValue: first) else {
            throw ValidationError("Unsupported batch step '\(first)'.")
        }
        if kind == .sleep {
            _ = try parseSleep(tokens)
            return
        }

        let stepArguments = Array(tokens.dropFirst())
        try ensureNoPerStepUDID(stepArguments)
        let arguments = stepArguments + ["--udid", globalUDID]

        switch kind {
        case .tap:
            _ = try parseStep(Tap.self, arguments: arguments)
            try PlatformSupport.check(.touch, on: platform)
        case .swipe:
            _ = try parseStep(Swipe.self, arguments: arguments)
            try PlatformSupport.check(.touch, on: platform)
        case .gesture:
            _ = try parseStep(Gesture.self, arguments: arguments)
            try PlatformSupport.check(.touch, on: platform)
        case .touch:
            _ = try parseStep(Touch.self, arguments: arguments)
            try PlatformSupport.check(.touch, on: platform)
        case .type:
            _ = try parseStep(Type.self, arguments: arguments)
            try PlatformSupport.check(.keyboard, on: platform)
        case .key:
            _ = try parseStep(Key.self, arguments: arguments)
            try PlatformSupport.check(.keyboard, on: platform)
        case .keySequence:
            _ = try parseStep(KeySequence.self, arguments: arguments)
            try PlatformSupport.check(.keyboard, on: platform)
        case .keyCombo:
            _ = try parseStep(KeyCombo.self, arguments: arguments)
            try PlatformSupport.check(.keyboard, on: platform)
        case .button:
            try parseStep(Button.self, arguments: arguments).buttonType.validate(for: platform)
        case .remote:
            _ = try parseStep(Remote.self, arguments: arguments)
            try PlatformSupport.check(.remote, on: platform)
        case .crown:
            _ = try parseStep(Crown.self, arguments: arguments)
            try PlatformSupport.check(.crown, on: platform)
        case .hinge:
            _ = try parseHinge(arguments)
            try PlatformSupport.requireIOS(command: kind.rawValue, on: platform)
        case .rotate:
            _ = try parseRotate(arguments)
            try PlatformSupport.requireIOS(command: kind.rawValue, on: platform)
        case .sleep:
            return
        }
    }

    nonisolated static let hingeStepFormat = "Hinge step format: hinge <set <degrees>|open|close|half> [--duration <s>] [--no-wait]"

    /// Parses `hinge set|open|close|half` with the `axe hinge` parser; `sweep` and `get` are not steps.
    nonisolated private static func parseHinge(_ arguments: [String]) throws -> DeviceStateAction {
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

    nonisolated static let rotateStepFormat = "Rotate step format: rotate <portrait|landscape|portrait-upside-down|landscape-flipped>"

    nonisolated private static func parseRotate(_ arguments: [String]) throws -> DeviceStateAction {
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
        let parsed = try parseStep(type, arguments: arguments)
        return try await parsed.toBatchPrimitives(context: context, logger: logger)
    }

    /// Parses and validates `arguments` with `C`'s parser. Sends nothing.
    nonisolated private static func parseStep<C: ParsableCommand>(_ type: C.Type, arguments: [String]) throws -> C {
        guard var parsed = try C.parseAsRoot(arguments) as? C else {
            throw CLIError(errorDescription: "Failed to parse batch step arguments: \(arguments.joined(separator: " "))")
        }
        try parsed.validate()
        return parsed
    }

    nonisolated private static func ensureNoPerStepUDID(_ args: [String]) throws {
        if args.contains(where: { $0 == "--udid" || $0.hasPrefix("--udid=") }) {
            throw ValidationError("Per-step --udid is not supported in batch steps. Use batch-level --udid.")
        }
    }

    nonisolated private static func parseSleep(_ tokens: [String]) throws -> [BatchPrimitive] {
        guard tokens.count == 2 else {
            throw ValidationError("Sleep step format: sleep <seconds>")
        }
        guard let seconds = Double(tokens[1]), seconds >= 0 else {
            throw ValidationError("Sleep step requires a non-negative number of seconds.")
        }
        return [.hostSleep(seconds)]
    }
}
