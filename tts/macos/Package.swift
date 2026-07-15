// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TTSMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TTSMenuBar", targets: ["TTSMenuBar"]),
        .library(
            name: "TTSMediaRemoteAdapter",
            type: .dynamic,
            targets: ["TTSMediaRemoteAdapter"]
        ),
    ],
    targets: [
        .target(
            name: "TTSMediaRemoteAdapter",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fvisibility=default"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "TTSMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "TTSMenuBarTests",
            dependencies: ["TTSMenuBar"]
        )
    ]
)
