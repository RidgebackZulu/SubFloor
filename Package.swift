// swift-tools-version: 6.0
import PackageDescription

let sdrplayLinker: [LinkerSetting] = [
    .unsafeFlags(["-L/usr/local/lib", "-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
]
let fastMath: [SwiftSetting] = [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]

let package = Package(
    name: "SubFloor",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CSDRplay", path: "Sources/CSDRplay"),
        .target(name: "DSPCore", swiftSettings: fastMath),
        .target(name: "Modems", dependencies: ["DSPCore"]),
        .target(name: "SubFloorCore", dependencies: ["DSPCore"]),
        .target(name: "SDRplayKit", dependencies: ["CSDRplay", "DSPCore"], linkerSettings: sdrplayLinker),
        .executableTarget(
            name: "SubFloor",
            dependencies: ["DSPCore", "SubFloorCore", "SDRplayKit", "Modems"],
            swiftSettings: fastMath,
            linkerSettings: sdrplayLinker),
        .testTarget(name: "DSPCoreTests", dependencies: ["DSPCore"]),
        .testTarget(name: "ModemsTests", dependencies: ["Modems", "DSPCore"]),
        .testTarget(name: "SubFloorCoreTests", dependencies: ["SubFloorCore", "DSPCore"]),
        .testTarget(name: "SDRplayKitTests", dependencies: ["SDRplayKit", "CSDRplay"], linkerSettings: sdrplayLinker),
        .testTarget(name: "SubFloorTests", dependencies: ["SubFloor"], linkerSettings: sdrplayLinker),
    ]
)
