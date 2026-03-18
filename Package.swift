// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Oatmeal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "oatmeal", targets: ["OatmealCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "OatmealCLI",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: ".",
            exclude: [
                "oatmeal/Services/MeetingDetector.swift",
                "oatmeal/App",
                "oatmeal/Views",
                "oatmeal/Assets.xcassets",
                "Scripts",
                "assets",
                "dist",
                "oatmeal.xcodeproj",
                "openola.xcodeproj",
                "LICENSE",
                "README.md",
                "appcast.xml",
                "skills-lock.json",
            ],
            sources: [
                "oatmeal/Models",
                "oatmeal/Services",
                "cli/Sources",
            ]
        ),
    ]
)
