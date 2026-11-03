// swift-tools-version:5.9
// Crepuscule - Package.swift
// Constantin Clerc (c22dev) - 0.1
import PackageDescription

let package = Package(
    name: "Crepuscule",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Crepuscule", targets: ["Crepuscule"]),
        .executable(name: "crepuscule-render", targets: ["crepuscule-render"]),
    ],
    targets: [
        .target(name: "Crepuscule", resources: [.copy("Resources/Shaders.metal"), .copy("Resources/Accumulate.metal")], swiftSettings: [.unsafeFlags(["-O"])]),
        .executableTarget(name: "crepuscule-render", dependencies: ["Crepuscule"]),
        .testTarget(name: "CrepusculeTests", dependencies: ["Crepuscule"]),
    ]
)
