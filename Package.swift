// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImageBrowser",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "ImageBrowser",
            path: "Sources/ImageBrowser",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        ),
    ]
)
