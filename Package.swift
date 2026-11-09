// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "hearsay",
    platforms: [.macOS(.v14)],
    dependencies: [
        // On-device ASR (NVIDIA Parakeet via CoreML on the Neural Engine). Apache-2.0.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.0"),
    ],
    targets: [
        .executableTarget(
            name: "hearsay",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/hearsay",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "hearsayTests",
            dependencies: ["hearsay"],
            path: "Tests/hearsayTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
