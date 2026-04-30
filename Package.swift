// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nudge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nudge", targets: ["Nudge"]),
        .executable(name: "nudge-hook", targets: ["NudgeHook"]),
        .executable(name: "nudge-ask", targets: ["NudgeAsk"]),
        .executable(name: "nudge-test-matching", targets: ["MatchingTestRunner"]),
    ],
    targets: [
        .target(
            name: "NudgeCore",
            path: "Sources/NudgeCore"
        ),
        .executableTarget(
            name: "Nudge",
            dependencies: ["NudgeCore"],
            path: "Sources/Nudge"
        ),
        .target(
            name: "NudgeHookCore",
            path: "Sources/NudgeHookCore"
        ),
        .executableTarget(
            name: "NudgeHook",
            dependencies: ["NudgeCore", "NudgeHookCore"],
            path: "Sources/NudgeHook"
        ),
        .executableTarget(
            name: "NudgeAsk",
            dependencies: ["NudgeCore"],
            path: "Sources/NudgeAsk"
        ),
        .executableTarget(
            name: "MatchingTestRunner",
            dependencies: ["NudgeHookCore", "NudgeCore"],
            path: "Sources/MatchingTestRunner"
        ),
        .testTarget(
            name: "NudgeTests",
            dependencies: ["NudgeCore"],
            path: "Tests/NudgeTests"
        ),
    ]
)
