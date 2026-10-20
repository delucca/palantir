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
      name: "PalantirNotebook",
      dependencies: [.product(name: "Markdown", package: "swift-markdown")],
      path: "Sources/Notebook/Model",
      swiftSettings: upcomingFeatures
    ),
    .target(
      name: "PalantirNotebookUI",
      dependencies: ["PalantirNotebook"],
      path: "Sources/Notebook/UI",
      swiftSettings: upcomingFeatures + [.defaultIsolation(MainActor.self)]
    ),
    .executableTarget(
      name: "Palantir",
      dependencies: ["PalantirNotebookUI"],
      path: "Sources/App",
      exclude: ["Info.plist"],
      swiftSettings: upcomingFeatures + [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(
      name: "PalantirNotebookTests",
      dependencies: ["PalantirNotebook"],
      path: "Tests/Notebook/Model",
      swiftSettings: upcomingFeatures
    ),
    .testTarget(
      name: "PalantirNotebookUITests",
      dependencies: ["PalantirNotebookUI"],
      path: "Tests/Notebook/UI",
      swiftSettings: upcomingFeatures
    ),
    .testTarget(
      name: "PalantirTests",
      dependencies: ["Palantir", "PalantirNotebook", "PalantirNotebookUI"],
      path: "Tests/App",
      swiftSettings: upcomingFeatures
    ),
  ]
)
