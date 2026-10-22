// swift-tools-version: 6.0
import PackageDescription

let sdrplayLinker: [LinkerSetting] = [
    .unsafeFlags(["-L/usr/local/lib", "-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
]
let fastMath: [SwiftSetting] = [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
/// Vendored ft8_lib (see Sources/CFT8/VENDORED.md): its sources include each other by root-relative
/// paths (<ft8/decode.h>), and its monitor logs to stderr unless LOG_PRINTF is defined.
let cft8Settings: [CSetting] = [
    .headerSearchPath("."),
    .define("LOG_PRINTF(...)", to: "((void)0)"),
    .unsafeFlags(["-O2"]),
]

let package = Package(
    name: "SubFloor",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CSDRplay", path: "Sources/CSDRplay"),
        .target(name: "DSPCore", swiftSettings: fastMath),
        .target(name: "CFT8", path: "Sources/CFT8", cSettings: cft8Settings),
        .target(name: "Modems", dependencies: ["DSPCore", "CFT8"]),
        .target(name: "SubFloorCore", dependencies: ["DSPCore"]),
        .target(name: "SDRplayKit", dependencies: ["CSDRplay", "DSPCore"], linkerSettings: sdrplayLinker),
        .executableTarget(
            name: "SubFloor",
            dependencies: ["DSPCore", "SubFloorCore", "SDRplayKit", "Modems"],
            resources: [.copy("Resources/AppIcon.png")],
            swiftSettings: fastMath,
            linkerSettings: sdrplayLinker),
        .testTarget(name: "DSPCoreTests", dependencies: ["DSPCore"]),
        .testTarget(name: "ModemsTests", dependencies: ["Modems", "DSPCore"]),
        .testTarget(name: "SubFloorCoreTests", dependencies: ["SubFloorCore", "DSPCore"]),
        .testTarget(name: "SDRplayKitTests", dependencies: ["SDRplayKit", "CSDRplay"], linkerSettings: sdrplayLinker),
        .testTarget(name: "SubFloorTests", dependencies: ["SubFloor"], linkerSettings: sdrplayLinker),
    ]
)
