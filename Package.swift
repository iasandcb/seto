// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sebeol390",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Sebeol390", targets: ["SetoIME"]),
    ],
    targets: [
        .target(name: "SetoCore"),
        .executableTarget(
            name: "SetoIME",
            dependencies: ["SetoCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "Sebeol390CoreTests",
            dependencies: ["SetoCore"],
            swiftSettings: [
                // Command Line Tools keep TestingMacros out of the default
                // plugin path, so `swift test` cannot see @Test / #expect.
                .unsafeFlags([
                    "-load-plugin-library",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib",
                ]),
            ]
        ),
    ]
)
