// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "NomasMotion",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "CAccelerometer",
            publicHeadersPath: "include"
        ),
        .target(
            name: "NomasMotionCore",
            dependencies: ["CAccelerometer"]
        ),
        .target(
            name: "NomasMotionOverlay",
            dependencies: ["NomasMotionCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "NomasMotion",
            dependencies: ["CAccelerometer", "NomasMotionCore", "NomasMotionOverlay"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMotion"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "NomasMotionSensorProbe",
            dependencies: ["CAccelerometer"],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "NomasMotionSensorBridge",
            dependencies: ["CAccelerometer", "NomasMotionCore"],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "NomasMotionPrivilegedHelper",
            dependencies: ["CAccelerometer", "NomasMotionCore"],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "NomasMotionVerify",
            dependencies: ["NomasMotionCore", "NomasMotionOverlay"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "NomasMotionCoreTests",
            dependencies: ["NomasMotionCore"]
        ),
        .testTarget(
            name: "NomasMotionAppTests",
            dependencies: ["NomasMotion"]
        ),
        .testTarget(
            name: "NomasMotionOverlayTests",
            dependencies: ["NomasMotionCore", "NomasMotionOverlay"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
