// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .library(name: "RappCore", targets: ["RappCore"]),
]

var targets: [Target] = [
    .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
    .target(name: "RappCore", dependencies: ["CZlib"]),
    .testTarget(name: "RappCoreTests", dependencies: ["RappCore"]),
]

// The host and client use ScreenCaptureKit / AppKit and only exist on macOS.
// RappCore and its tests build anywhere Swift and zlib are available.
#if os(macOS)
products += [
    .executable(name: "rapp-host", targets: ["rapp-host"]),
    .executable(name: "rapp-client", targets: ["rapp-client"]),
]
targets += [
    .executableTarget(name: "rapp-host", dependencies: ["RappCore"]),
    .executableTarget(name: "rapp-client", dependencies: ["RappCore"]),
]
#endif

let package = Package(
    name: "rapp",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
