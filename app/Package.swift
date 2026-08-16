// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Alap",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "Alap",
      path: "Sources/Alap",
      resources: [
        // The Zero client bundle, copied here by scripts/build-app.sh from
        // packages/client/dist. `.copy` (not `.process`) so the directory
        // structure is preserved verbatim — WKWebView loads index.html by
        // file URL and resolves ./bridge.js relative to it.
        .copy("Web")
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "AlapTests",
      dependencies: ["Alap"],
      path: "Tests/AlapTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
