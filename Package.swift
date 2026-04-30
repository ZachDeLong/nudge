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
        .executableTarget(
            name: "Nudge",
            path: "Sources/Nudge"
        ),
        .target(
            name: "NudgeHookCore",
            path: "Sources/NudgeHookCore"
        ),
        .executableTarget(
            name: "NudgeHook",
            dependencies: ["NudgeHookCore"],
            path: "Sources/NudgeHook"
        ),
        .executableTarget(
            name: "NudgeAsk",
            path: "Sources/NudgeAsk"
        ),
        .executableTarget(
            name: "MatchingTestRunner",
            dependencies: ["NudgeHookCore"],
            path: "Sources/MatchingTestRunner"
        ),
    ]
)
