// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChargeLimitApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ChargeLimitApp", targets: ["ChargeLimitApp"]),
        .executable(name: "ChargeLimitHelper", targets: ["ChargeLimitHelper"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ChargeLimitService",
            dependencies: [],
            path: "Sources/ChargeLimitService",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "ChargeLimitApp",
            dependencies: ["ChargeLimitService"],
            path: "Sources/ChargeLimitApp",
            resources: [
                .copy("Resources"),
                .copy("Resources/com.denissmoliakov.ChargeLimitHelper.plist")
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "ChargeLimitHelper",
            dependencies: ["ChargeLimitService"],
            path: "Sources/ChargeLimitHelper",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)