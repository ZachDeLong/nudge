// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nudge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nudge", targets: ["Nudge"]),
        .executable(name: "nudge-hook", targets: ["NudgeHook"]),
        .executable(name: "nudge-ask", targets: ["NudgeAsk"]),
    ],
    targets: [
        .executableTarget(
            name: "Nudge",
            path: "Sources/Nudge"
        ),
        .executableTarget(
            name: "NudgeHook",
            path: "Sources/NudgeHook"
        ),
        .executableTarget(
            name: "NudgeAsk",
            path: "Sources/NudgeAsk"
        ),
    ]
)
