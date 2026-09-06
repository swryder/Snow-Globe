// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnowGlobe",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SnowGlobe", targets: ["SnowGlobe"])],
    targets: [
        .target(name: "SnowGlobe", resources: [.process("Shaders")]),
        .testTarget(name: "SnowGlobeTests", dependencies: ["SnowGlobe"],
                    resources: [.copy("Fixtures")])
    ]
)
