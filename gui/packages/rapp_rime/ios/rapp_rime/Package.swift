// swift-tools-version: 5.9
import PackageDescription

let libs = [
  "librime", "boost_filesystem", "boost_regex", "boost_system", "boost_thread",
  "libglog", "libleveldb", "libmarisa", "libopencc", "libyaml-cpp",
]

let package = Package(
  name: "rapp_rime",
  platforms: [.iOS("17.0")],
  products: [
    .library(name: "rapp-rime", targets: ["rapp_rime"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    // Headers only; the engine itself comes from the binary targets below (run scripts/fetch.sh first).
    .target(name: "CRime", path: "Sources/CRime"),
    .target(name: "RappRimeKeys", path: "Sources/RappRimeKeys"),
    .target(
      name: "rapp_rime",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        "CRime", "RappRimeKeys",
      ] + libs.map { .target(name: $0) },
      path: "Sources/rapp_rime",
      resources: [.copy("RimeData")],
      linkerSettings: [.linkedLibrary("c++")]
    ),
  ] + libs.map { .binaryTarget(name: $0, path: "Frameworks/\($0).xcframework") }
)
