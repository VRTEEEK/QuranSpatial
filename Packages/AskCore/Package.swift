// swift-tools-version: 6.2
// AskCore - the "Ask" companion's core, separate from the app target so the same code runs
// in the visionOS app and in the macOS command-line tool the judges can run (qs-ask).
import PackageDescription

let package = Package(
    name: "AskCore",
    platforms: [.macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "AskCore", targets: ["AskCore"]),
        .executable(name: "qs-ask", targets: ["qs-ask"]),
    ],
    targets: [
        .target(name: "AskCore"),
        .executableTarget(name: "qs-ask", dependencies: ["AskCore"]),
        .testTarget(name: "AskCoreTests", dependencies: ["AskCore"]),
    ]
)
