// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "videxo-swift",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "Videxo", targets: ["Videxo"])],
    targets: [
        .target(name: "Videxo"),
        .testTarget(name: "VidexoTests", dependencies: ["Videxo"], resources: [.copy("Fixtures")]),
    ]
)
