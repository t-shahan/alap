// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Alap",
  // 14.4, not 14.0, and the reason is `@scope`.
  //
  // The reading pane composes a whole thread into ONE document, so a retained
  // sender stylesheet is global to it — one newsletter's `td { font-size: 18px }`
  // restyles the reply above it. Scoping each message's rules to its own article
  // is what stops that, and `@scope` is the only way to do it without rewriting
  // every selector by hand.
  //
  // WebKit shipped `@scope` in Safari 17.4, which is macOS 14.4. Below that an
  // unknown at-rule is dropped ALONG WITH ITS BLOCK — so a 14.0 machine would
  // discard the sender's stylesheet entirely and render the collapsed layouts
  // the engine's CSS work exists to prevent. Silently, and worse than doing
  // nothing.
  //
  // The floor moves rather than the feature being conditional, because 14.4 is
  // two and a half years old and shipped as a point update everyone on 14.x
  // already took. There is no installed base to strand.
  platforms: [.macOS("14.4")],
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
