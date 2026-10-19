// swift-tools-version: 6.4

import PackageDescription

let upcomingFeatures: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "palantir",
  platforms: [.macOS(.v27)],
  products: [
    .executable(name: "palantir", targets: ["Palantir"])
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")
  ],
  targets: [
    .target(
      name: "PalantirCore",
      dependencies: [.product(name: "Markdown", package: "swift-markdown")],
      swiftSettings: upcomingFeatures
    ),
    .executableTarget(
      name: "Palantir",
      dependencies: ["PalantirCore"],
      exclude: ["Info.plist"],
      swiftSettings: upcomingFeatures + [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(
      name: "PalantirCoreTests",
      dependencies: ["PalantirCore"],
      swiftSettings: upcomingFeatures
    ),
    .testTarget(
      name: "PalantirTests",
      dependencies: ["Palantir", "PalantirCore"],
      swiftSettings: upcomingFeatures
    ),
  ]
)
