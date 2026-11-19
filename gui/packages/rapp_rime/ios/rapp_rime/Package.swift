// swift-tools-version: 5.9
import Foundation
import PackageDescription

let libs = [
  "librime", "boost_filesystem", "boost_regex", "boost_system", "boost_thread",
  "libglog", "libleveldb", "libmarisa", "libopencc", "libyaml-cpp",
]

let keysOnly = ProcessInfo.processInfo.environment["RAPP_RIME_KEYS_ONLY"].map { !$0.isEmpty } ?? false

let package = keysOnly
  ? Package(
    name: "rapp_rime",
    platforms: [.macOS(.v13)],
    products: [],
    targets: [
      .target(name: "RappRimeKeys", path: "Sources/RappRimeKeys"),
      .testTarget(name: "RappRimeKeysTests", dependencies: ["RappRimeKeys"], path: "Tests/RappRimeKeysTests"),
    ]
  )
  : Package(
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
    .testTarget(name: "RappRimeKeysTests", dependencies: ["RappRimeKeys"], path: "Tests/RappRimeKeysTests"),
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
