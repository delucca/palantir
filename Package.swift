// swift-tools-version: 6.2

import PackageDescription

let upcomingFeatures: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "palantir",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "palantir", targets: ["Palantir"])
  ],
  targets: [
    .executableTarget(
      name: "Palantir",
      exclude: ["Info.plist"],
      swiftSettings: upcomingFeatures + [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(
      name: "PalantirTests",
      dependencies: ["Palantir"],
      swiftSettings: upcomingFeatures
    ),
  ]
)
