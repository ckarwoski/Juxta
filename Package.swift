// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Juxta",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JuxtaCore", targets: ["JuxtaCore"]),
        .executable(name: "Juxta", targets: ["Juxta"]),
        .executable(name: "juxta-diff", targets: ["juxta-diff"]),
    ],
    targets: [
        .target(name: "JuxtaCore"),
        .executableTarget(name: "Juxta", dependencies: ["JuxtaCore"]),
        .executableTarget(name: "juxta-diff", dependencies: ["JuxtaCore"]),
        .testTarget(name: "JuxtaCoreTests", dependencies: ["JuxtaCore"]),
    ]
)
