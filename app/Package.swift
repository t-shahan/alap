// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Mail",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "Mail",
      path: "Sources/Mail",
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
      name: "MailTests",
      dependencies: ["Mail"],
      path: "Tests/MailTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
