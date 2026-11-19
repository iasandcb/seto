// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sebeol390",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SetoCore", targets: ["SetoCore"]),
        .executable(name: "Sebeol390", targets: ["SetoIME"]),
    ],
    targets: [
        // Built by scripts/build-apple-xcframework.sh (and Xcode Cloud's ci_post_clone.sh).
        .binaryTarget(name: "seto_ffiFFI", path: "Apple/SetoFFI.xcframework"),
        .target(
            name: "seto_ffi",
            dependencies: ["seto_ffiFFI"],
            path: "Apple/Generated"
        ),
        .target(name: "SetoSupport", path: "Sources/SetoSupport"),
        .target(
            name: "SetoOracle",
            dependencies: ["SetoSupport"],
            path: "Sources/SetoOracle"
        ),
        .target(
            name: "SetoCore",
            dependencies: ["SetoSupport", "seto_ffi"],
            path: "Sources/SetoCore"
        ),
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

// Golden corpus for the shared Rust core (core-rs/testdata/session-golden.json).
// Only built on request so a plain `swift test` never rewrites it:
//     SETO_GOLDEN_DUMP=1 swift test --filter SetoGoldenDump
// The dump still drives the Swift oracle (SetoOracle), not the Rust adapter.
if Context.environment["SETO_GOLDEN_DUMP"] != nil {
    package.targets.append(
        .testTarget(
            name: "SetoGoldenDump",
            dependencies: ["SetoOracle"],
            swiftSettings: [
                .define("SETO_ORACLE"),
                .unsafeFlags([
                    "-load-plugin-library",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib",
                ]),
            ]
        )
    )
}
