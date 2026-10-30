import ArgumentParser
import Foundation
import FBSimulatorControl

@MainActor
protocol BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive]
}

private func buildDelayedEvent(
    preDelay: Double?,
    mainEvent: SimulatorHIDEvent,
    postDelay: Double?
) -> SimulatorHIDEvent {
    var events: [SimulatorHIDEvent] = []
    if let preDelay, preDelay > 0 {
        events.append(.delay(preDelay))
    }
    events.append(mainEvent)
    if let postDelay, postDelay > 0 {
        events.append(.delay(postDelay))
    }
    return events.count == 1 ? events[0] : SimulatorHIDEvent.composite(events)
}

private func resolveBatchTapPoint(
    query: AccessibilityQuery,
    context: BatchContext,
    elementType: String?,
    logger: AxeLogger
) async throws -> (resolution: TapResolution, roots: [AccessibilityElement]) {
    var isFirstFetch = true
    var latestRoots: [AccessibilityElement] = []
    // Display state is re-read per step, so the target follows a fold or rotation between steps.
    let target = try await TouchTarget.nonMainTarget(forSimulatorUDID: context.simulatorUDID, logger: logger)
    let resolution = try await AccessibilityPoller.pollForResolution(
        query: query,
        waitTimeout: context.waitTimeout,
        pollInterval: context.pollInterval,
        elementType: elementType,
        target: target,
        platform: SimulatorSession.platform(udid: context.simulatorUDID, logger: logger),
        logger: logger
    ) {
        let forceRefresh = !isFirstFetch
        isFirstFetch = false
        let roots = try await context.accessibilityRoots(logger: logger, forceRefresh: forceRefresh)
        latestRoots = roots
        return roots
    }
    return (resolution, latestRoots)
}

func parseCommaSeparatedIntsStrict(_ rawValue: String, fieldName: String) throws -> [Int] {
    let rawTokens = rawValue
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespaces) }

    let invalidTokens = rawTokens.filter { token in
        token.isEmpty || Int(token) == nil
    }
    guard invalidTokens.isEmpty else {
        throw ValidationError("All \(fieldName) must be valid integers. Invalid token(s): \(invalidTokens.joined(separator: ", "))")
    }

    return rawTokens.compactMap(Int.init)
}

extension Tap: BatchConvertible {
    private func resolvedTapStyle(for resolution: TapResolution, context: BatchContext) -> TapStyle {
        let requestedStyle = tapStyle ?? context.tapStyle
        switch requestedStyle {
        case .automatic:
            return resolution.isSwitchLikeControl ? .physical : .simulator
        case .simulator:
            return .simulator
        case .physical:
            return .physical
        }
    }

    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        try PlatformSupport.check(.touch, simulatorUDID: context.simulatorUDID, logger: logger)
        let resolution: TapResolution
        let resolvedRoots: [AccessibilityElement]?

        if let pointX, let pointY {
            resolution = TapResolution(point: (x: pointX, y: pointY), isSwitchLikeControl: false)
            resolvedRoots = nil
        } else {
            let query: AccessibilityQuery
            if let elementID {
                query = .id(elementID)
            } else if let elementLabel {
                query = .label(elementLabel)
            } else if let elementValue {
                query = .value(elementValue)
            } else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            let resolved = try await resolveBatchTapPoint(
                query: query,
                context: context,
                elementType: elementType,
                logger: logger
            )
            resolution = resolved.resolution
            resolvedRoots = resolved.roots
        }

        let physicalPoint: (x: Double, y: Double)
        if let resolvedRoots {
            physicalPoint = try await OrientationAwareCoordinates.translate(
                point: resolution.point,
                roots: resolvedRoots,
                for: context.simulatorUDID,
                logger: logger
            )
        } else {
            physicalPoint = try await OrientationAwareCoordinates.translate(
                point: resolution.point,
                for: context.simulatorUDID,
                logger: logger
            )
        }

        let style = resolvedTapStyle(for: resolution, context: context)
        switch style {
        case .physical:
            return [.physicalTap(point: physicalPoint, preDelay: preDelay, postDelay: postDelay)]
        case .simulator:
            let tapEvent = SimulatorHIDEvent.tapAt(x: physicalPoint.x, y: physicalPoint.y)
            return [.hidMergeable(buildDelayedEvent(preDelay: preDelay, mainEvent: tapEvent, postDelay: postDelay))]
        case .automatic:
            throw CLIError(errorDescription: "Unexpected tap style resolution.")
        }
    }
}

extension Swipe: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        try PlatformSupport.check(.touch, simulatorUDID: context.simulatorUDID, logger: logger)
        let swipeDuration = duration ?? 1.0
        let swipeDelta = delta ?? 50.0
        let physicalPoints = try await OrientationAwareCoordinates.translateBatch(
            points: [(x: startX, y: startY), (x: endX, y: endY)],
            for: context.simulatorUDID,
            logger: logger
        )
        let physicalStart = physicalPoints[0]
        let physicalEnd = physicalPoints[1]

        let swipeEvent = SimulatorHIDEvent.swipe(
            physicalStart.x,
            yStart: physicalStart.y,
            xEnd: physicalEnd.x,
            yEnd: physicalEnd.y,
            delta: swipeDelta,
            duration: swipeDuration
        )
        return [.hidMergeable(buildDelayedEvent(preDelay: preDelay, mainEvent: swipeEvent, postDelay: postDelay))]
    }
}

extension Gesture: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let platform = try PlatformSupport.check(.touch, simulatorUDID: context.simulatorUDID, logger: logger)
        let target = try await TouchTarget.nonMainTarget(forSimulatorUDID: context.simulatorUDID, logger: logger)
        let mainScreen = mainScreenSize(platform: platform, simulatorUDID: context.simulatorUDID, logger: logger)
        let coords = try coordinates(target: target, mainScreen: mainScreen)
        let gestureDuration = duration ?? preset.defaultDuration
        let gestureDelta = delta ?? preset.defaultDelta

        let gestureEvent = SimulatorHIDEvent.swipe(
            coords.startX,
            yStart: coords.startY,
            xEnd: coords.endX,
            yEnd: coords.endY,
            delta: gestureDelta,
            duration: gestureDuration
        )

        return [.hidMergeable(buildDelayedEvent(preDelay: preDelay, mainEvent: gestureEvent, postDelay: postDelay))]
    }
}

extension Touch: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        try PlatformSupport.check(.touch, simulatorUDID: context.simulatorUDID, logger: logger)
        let physicalPoint = try await OrientationAwareCoordinates.translate(
            point: (x: pointX, y: pointY),
            for: context.simulatorUDID,
            logger: logger
        )

        let touchDownEvent = SimulatorHIDEvent.touch(direction: .down, x: physicalPoint.x, y: physicalPoint.y)
        let touchUpEvent = SimulatorHIDEvent.touch(direction: .up, x: physicalPoint.x, y: physicalPoint.y)

        if touchDown && touchUp {
            let holdDelay = delay ?? TapTiming.defaultHoldDuration
            return [
                .hidBarrier(touchDownEvent),
                .hostSleep(holdDelay),
                .hidBarrier(touchUpEvent)
            ]
        }

        if touchDown {
            return [.hidMergeable(touchDownEvent)]
        }

        return [.hidMergeable(touchUpEvent)]
    }
}

extension Button: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        try buttonType.validate(simulatorUDID: context.simulatorUDID, logger: logger)
        return [.buttonPress(buttonType, duration: duration)]
    }
}

extension Remote: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        try PlatformSupport.check(.remote, simulatorUDID: context.simulatorUDID, logger: logger)
        return [.hidMergeable(event)]
    }
}

extension Key: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        try PlatformSupport.check(.keyboard, simulatorUDID: context.simulatorUDID, logger: logger)
        if let duration {
            let composite = SimulatorHIDEvent.composite([
                .keyboard(direction: .down, keyCode: UInt32(keycode)),
                .delay(duration),
                .keyboard(direction: .up, keyCode: UInt32(keycode))
            ])
            return [.hidMergeable(composite)]
        }

        return [.hidMergeable(.shortKeyPress(UInt32(keycode)))]
    }
}

extension KeySequence: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        try PlatformSupport.check(.keyboard, simulatorUDID: context.simulatorUDID, logger: logger)
        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        let keyDelay = delay ?? 0.1
        var events: [SimulatorHIDEvent] = []

        for (index, keycode) in parsedKeycodes.enumerated() {
            events.append(.shortKeyPress(UInt32(keycode)))
            if index < parsedKeycodes.count - 1 && keyDelay > 0 {
                events.append(.delay(keyDelay))
            }
        }

        return [.hidMergeable(SimulatorHIDEvent.composite(events))]
    }
}

extension KeyCombo: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        try PlatformSupport.check(.keyboard, simulatorUDID: context.simulatorUDID, logger: logger)
        let parsedModifiers = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")

        var events: [SimulatorHIDEvent] = []
        for modifier in parsedModifiers {
            events.append(.keyboard(direction: .down, keyCode: UInt32(modifier)))
        }
        events.append(.shortKeyPress(UInt32(key)))
        for modifier in parsedModifiers.reversed() {
            events.append(.keyboard(direction: .up, keyCode: UInt32(modifier)))
        }

        return [.hidMergeable(SimulatorHIDEvent.composite(events))]
    }
}

extension Type: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        try PlatformSupport.check(.keyboard, simulatorUDID: context.simulatorUDID, logger: logger)
        let inputText: String
        switch (text, useStdin, inputFile) {
        case (let positionalText?, false, nil):
            inputText = positionalText
        case (nil, true, nil):
            inputText = readFromStdin()
        case (nil, false, let file?):
            inputText = try readFromFile(file)
        default:
            throw CLIError(errorDescription: "Invalid input configuration.")
        }

        guard TextToHIDEvents.validateText(inputText) else {
            let unsupportedChars = inputText.compactMap { char in
                let keyEvent = KeyEvent.keyCodeForString(String(char))
                return keyEvent.keyCode == 0 ? char : nil
            }
            throw TextToHIDEvents.TextConversionError.unsupportedCharacter(unsupportedChars.first ?? " ")
        }

        let hidEvents = try TextToHIDEvents.convertTextToHIDEvents(inputText)
        guard !hidEvents.isEmpty else {
            return []
        }

        switch context.typeSubmissionMode {
        case .composite:
            return [.hidMergeable(SimulatorHIDEvent.composite(hidEvents))]
        case .chunked:
            let chunkSize = max(1, context.typeChunkSize)
            var primitives: [BatchPrimitive] = []
            var start = 0
            while start < hidEvents.count {
                let end = min(start + chunkSize, hidEvents.count)
                let chunkEvents = Array(hidEvents[start..<end])
                primitives.append(.hidBarrier(SimulatorHIDEvent.composite(chunkEvents)))
                start = end
            }
            return primitives
        }
    }
}
