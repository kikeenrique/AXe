import ArgumentParser
import Foundation
import FBSimulatorControl

struct Hinge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set or read the hinge angle of a foldable simulator (iPhone Duo).",
        discussion: """
        Angles run from 0 (closed, cover display active) to 180 (flat, inner display active).
        On iOS 27.2 and later runtimes the angle is set directly, or swept over --duration;
        older runtimes always sweep from the current angle over at least 0.4 s (from the
        opposite end when the angle cannot be read), since a direct 0-180 jump left iOS 27.1
        unable to switch displays. AXe then confirms the angle the simulator reports and waits
        up to 8 s for the cover (<= 30 degrees) or inner (>= 120 degrees) display to become
        active and lit. Device Hub's half-open preset is 130 degrees. Hinge commands need a
        simulator that reports a hinge (iPhone Duo, iOS 27.1 or later).

        Examples:
          axe hinge close --udid SIMULATOR_UDID
          axe hinge open --duration 1.5 --udid SIMULATOR_UDID
          axe hinge set 130 --udid SIMULATOR_UDID
          axe hinge get --udid SIMULATOR_UDID
        """,
        subcommands: [
            SetAngle.self,
            Open.self,
            Close.self,
            Half.self,
            Sweep.self,
            Get.self,
        ]
    )
}

// MARK: - Shared Options

struct HingeTargetOptions: ParsableArguments {
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Option(name: .customLong("duration"), help: "Seconds to sweep the hinge over, 0 to 30. 0 sets the angle directly on iOS 27.2 and later; sweeps last at least 0.4 s otherwise.")
    var duration: Double = 0

    @Flag(name: .customLong("no-wait"), help: "Do not wait for the expected display to become active; the printed posture is read at once and may still be changing.")
    var noWait: Bool = false

    @Flag(name: .customLong("json"), help: "Print the resulting posture as JSON.")
    var json: Bool = false

    func validate() throws {
        guard duration.isFinite, duration >= 0, duration <= HingeRules.maximumDuration else {
            throw ValidationError("--duration must be between 0 and \(Int(HingeRules.maximumDuration)) seconds.")
        }
    }
}

/// A hinge subcommand that moves the hinge; batch `hinge` steps accept these.
protocol HingeMoving: AsyncParsableCommand {
    var options: HingeTargetOptions { get }
    var action: DeviceStateAction { get }
}

extension HingeMoving {
    static var unsettledPostureNote: String {
        "Posture right after the move (--no-wait): the displays may still be changing."
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let simulator = try await FoldableDevice.bootedSimulator(udid: options.simulatorUDID, logger: logger)
        if let warning = try await FoldableDevice.perform(action, simulator: simulator, logger: logger) {
            print("Warning: \(warning)", to: &standardError)
        }
        // With --no-wait the posture is read as it is right now, without waiting for the fold to settle.
        let settled = !options.noWait
        let posture = try await FoldableDevice.posture(simulator: simulator, settled: settled, logger: logger)
        if options.json {
            if !settled {
                print(Self.unsettledPostureNote, to: &standardError)
            }
            print(try posture.jsonString())
        } else {
            if !settled {
                print(Self.unsettledPostureNote)
            }
            print(posture.textSummary)
        }
    }
}

extension Hinge {
    struct SetAngle: HingeMoving {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set the hinge angle in degrees (0 closed, 180 flat)."
        )

        @Argument(help: "Hinge angle in degrees, 0 to 180.")
        var degrees: Double

        @OptionGroup var options: HingeTargetOptions

        func validate() throws {
            try HingeRules.validate(degrees)
        }

        var action: DeviceStateAction {
            .hinge(target: degrees, duration: options.duration, waitForDisplay: !options.noWait)
        }
    }

    struct Open: HingeMoving {
        static let configuration = CommandConfiguration(abstract: "Unfold the simulator flat (180 degrees).")

        @OptionGroup var options: HingeTargetOptions

        var action: DeviceStateAction {
            .hinge(target: 180, duration: options.duration, waitForDisplay: !options.noWait)
        }
    }

    struct Close: HingeMoving {
        static let configuration = CommandConfiguration(abstract: "Fold the simulator closed (0 degrees).")

        @OptionGroup var options: HingeTargetOptions

        var action: DeviceStateAction {
            .hinge(target: 0, duration: options.duration, waitForDisplay: !options.noWait)
        }
    }

    struct Half: HingeMoving {
        static let configuration = CommandConfiguration(
            abstract: "Half-open the simulator (90 degrees). Device Hub's own half-open preset is 130 degrees."
        )

        @OptionGroup var options: HingeTargetOptions

        var action: DeviceStateAction {
            .hinge(target: 90, duration: options.duration, waitForDisplay: !options.noWait)
        }
    }

    struct Sweep: HingeMoving {
        static let configuration = CommandConfiguration(
            abstract: "Sweep the hinge between two angles, for example to record a fold animation.",
            discussion: "The sweep lasts --duration, at least 0.4 s. When the hinge is not at <from>, AXe first moves it there (directly on iOS 27.2 and later, otherwise over 0.4 s)."
        )

        @Argument(help: "Start angle in degrees, 0 to 180.")
        var from: Double

        @Argument(help: "End angle in degrees, 0 to 180.")
        var to: Double

        @OptionGroup var options: HingeTargetOptions

        func validate() throws {
            try HingeRules.validate(from, name: "Start angle")
            try HingeRules.validate(to, name: "End angle")
        }

        var action: DeviceStateAction {
            .sweep(from: from, to: to, duration: options.duration, waitForDisplay: !options.noWait)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the hinge angle the simulator reports.")

        @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
        var simulatorUDID: String

        @Flag(name: .customLong("json"), help: "Print the posture as JSON.")
        var json: Bool = false

        func run() async throws {
            let logger = AxeLogger()
            try await setup(logger: logger)
            try await performGlobalSetup(logger: logger)

            let simulator = try await FoldableDevice.bootedSimulator(udid: simulatorUDID, logger: logger)
            let angle = try await FoldableDevice.requireAngle(simulator: simulator, logger: logger)
            if json {
                print(try await FoldableDevice.posture(simulator: simulator, hingeAngle: angle, logger: logger).jsonString())
            } else {
                print(HingeRules.formatted(angle))
            }
        }
    }
}
