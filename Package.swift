// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nudge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nudge", targets: ["Nudge"]),
        .executable(name: "nudge-hook", targets: ["NudgeHook"]),
        .executable(name: "nudge-agent-hook", targets: ["NudgeAgentHook"]),
        .executable(name: "nudge-ask", targets: ["NudgeAsk"]),
        .executable(name: "nudge-claude", targets: ["NudgeClaude"]),
        .executable(name: "nudge-update", targets: ["NudgeUpdate"]),
        .executable(name: "nudge-test-matching", targets: ["MatchingTestRunner"]),
        .executable(name: "nudge-test-e2e", targets: ["E2ETestRunner"]),
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
            name: "NudgeAgentHook",
            dependencies: ["NudgeCore", "NudgeHookCore"],
            path: "Sources/NudgeAgentHook"
        ),
        .executableTarget(
            name: "NudgeAsk",
            dependencies: ["NudgeCore"],
            path: "Sources/NudgeAsk"
        ),
        .executableTarget(
            name: "NudgeClaude",
            dependencies: ["NudgeCore"],
            path: "Sources/NudgeClaude"
        ),
        .executableTarget(
            name: "NudgeUpdate",
            dependencies: ["NudgeCore"],
            path: "Sources/NudgeUpdate"
        ),
        .executableTarget(
            name: "MatchingTestRunner",
            dependencies: ["NudgeHookCore", "NudgeCore"],
            path: "Sources/MatchingTestRunner"
        ),
        .executableTarget(
            name: "E2ETestRunner",
            path: "Sources/E2ETestRunner"
        ),
        .testTarget(
            name: "NudgeTests",
            dependencies: ["NudgeCore"],
            path: "Tests/NudgeTests"
        ),
    ]
)
