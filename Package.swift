// swift-tools-version:5.10
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let idbCheckoutDirectory = ProcessInfo.processInfo.environment["IDB_CHECKOUT_DIR"]
    .map { URL(fileURLWithPath: $0) }
    ?? packageRoot.appendingPathComponent("idb_checkout", isDirectory: true)
let idbPrivateHeadersDirectory = idbCheckoutDirectory.appendingPathComponent(
    "PrivateHeaders",
    isDirectory: true
)
// Static archives and their Swift modules side by side, installed by `scripts/build.sh libraries`.
let idbLibraryDirectory = packageRoot
    .appendingPathComponent("build_products/idb/lib", isDirectory: true)

// The upstream IDB libraries AXe links, in link order. Keep in sync with IDB_LIBRARIES in
// scripts/build.sh. FBSimulatorVideo and FBVideoCore back `stream-video`.
let idbArchives = [
    "FBSimulatorAX",
    "FBSimulatorServices",
    "FBSimulatorVideo",
    "FBVideoCore",
    "FBSimulatorControl",
    "FBSimulatorBridgeProtocol",
    "SimulatorIPC",
    "FBControlCore",
    "FBControlCoreObjC",
    "IDBConcurrency",
]

// Private frameworks whose module maps the IDB Swift modules import.
let idbPrivateModuleMaps = [
    "AXRuntime",
    "AccessibilityPlatformTranslation",
    "CoreSimDeviceIO",
    "CoreSimulator",
    "CoreSimulatorUtilities",
    "DTXConnectionServices",
    "SimulatorApp",
    "SimulatorKit",
]

// Compile-only module-map inputs: never copy these headers into release artifacts or runtime rpaths.
// Keep each search path in one token. SwiftPM can otherwise drop the path while propagating
// unsafe flags to its generated test runner, leaving a bare `-I` that consumes the next option.
let idbCompilerFlags = [
    idbLibraryDirectory,
    idbPrivateHeadersDirectory,
    idbPrivateHeadersDirectory.appendingPathComponent("AccessibilityPlatformTranslation", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("AXRuntime", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("CoreSimDeviceIO", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("CoreSimulator", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("CoreSimulatorUtilities", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("SimulatorKit", isDirectory: true),
    // Clang module of the Objective-C library the IDB Swift modules import. (ZstdDecompress is used
    // only by FBArtifactStaging, which AXe does not link.)
    idbCheckoutDirectory.appendingPathComponent("FBControlCoreObjC/include", isDirectory: true),
].map { "-I\($0.path)" } + idbPrivateModuleMaps.flatMap { name in
    [
        "-Xcc",
        "-fmodule-map-file=\(idbPrivateHeadersDirectory.appendingPathComponent("\(name)/module.modulemap").path)",
    ]
}

// IDB is linked statically: the executable embeds no frameworks. CoreSimulator and
// AccessibilityPlatformTranslation are weak-linked through the stubs in the checkout, as upstream's
// manifest prescribes, and resolved at run time from the selected Xcode / the OS.
let idbLinkerFlags = ["-L\(idbLibraryDirectory.path)"]
    + idbArchives.map { "-l\($0)" }
    + [
        "-Xlinker", "-weak_library", "-Xlinker",
        idbPrivateHeadersDirectory.appendingPathComponent("CoreSimulator/CoreSimulator.tbd").path,
        "-Xlinker", "-weak_library", "-Xlinker",
        idbPrivateHeadersDirectory
            .appendingPathComponent("AccessibilityPlatformTranslation/AccessibilityPlatformTranslation.tbd").path,
    ]

// System frameworks the linked IDB libraries need (union of upstream's LibraryPackage.json entries).
let idbSystemFrameworks = [
    "AppKit",
    "AVFoundation",
    "Cocoa",
    "CoreGraphics",
    "CoreImage",
    "CoreMedia",
    "CoreText",
    "CoreVideo",
    "ImageIO",
    "IOSurface",
    "Metal",
    "QuartzCore",
    "ServiceManagement",
    "UniformTypeIdentifiers",
    "VideoToolbox",
].map { LinkerSetting.linkedFramework($0) }

let package = Package(
    name: "AXe",
    platforms: [
        // Upstream IDB v1.7.7 requires macOS 15.
        .macOS("15.0")
    ],
    products: [
        .library(
            name: "AXeCore",
            targets: ["AXeCore"]
        ),
        .executable(
            name: "axe",
            targets: ["AXe"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AXeCore",
            path: "Sources/AXeCore"
        ),
        .executableTarget(
            name: "AXe",
            dependencies: [
                "AXeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AXe",
            resources: [
                .copy("Resources/skills")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"] + idbCompilerFlags)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-dead_strip",
                    "-Xlinker", "-headerpad_max_install_names",
                ] + idbLinkerFlags)
            ] + idbSystemFrameworks,
            plugins: ["VersionPlugin"]
        ),
        .testTarget(
            name: "AXeTests",
            dependencies: ["AXe", "AXeCore"],
            path: "Tests",
            exclude: ["Goldens"],
            swiftSettings: [
                .unsafeFlags(idbCompilerFlags)
            ]
        ),
        .plugin(
            name: "VersionPlugin",
            capability: .buildTool(),
            path: "Plugins/VersionPlugin"
        ),
    ]
)
