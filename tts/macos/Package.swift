// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TTSMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TTSMenuBar", targets: ["TTSMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "TTSMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "TTSMenuBarTests",
            dependencies: ["TTSMenuBar"]
        )
    ]
)
