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
    .executable(name: "palantir", targets: ["Palantir"]),
    .executable(name: "palantir-inspect", targets: ["PalantirInspectorCLI"]),
    .executable(name: "palantir-drive", targets: ["PalantirDriver"]),
    .executable(name: "palantir-accept", targets: ["PalantirAcceptance"]),
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
    .target(
      name: "PalantirNotebookInspector",
      dependencies: ["PalantirInspector", "PalantirNotebook", "PalantirNotebookUI"],
      path: "Sources/Notebook/Inspector",
      swiftSettings: upcomingFeatures + [.defaultIsolation(MainActor.self)]
    ),
    .target(
      name: "PalantirInspector",
      path: "Sources/Inspector",
      exclude: ["CLI"],
      swiftSettings: upcomingFeatures
    ),
    .executableTarget(
      name: "PalantirInspectorCLI",
      dependencies: ["PalantirInspector"],
      path: "Sources/Inspector/CLI",
      swiftSettings: upcomingFeatures
    ),
    .executableTarget(
      name: "PalantirDriver",
      path: "Sources/Driver",
      swiftSettings: upcomingFeatures
    ),
    .executableTarget(
      name: "PalantirAcceptance",
      path: "Sources/Acceptance",
      resources: [.copy("Resources")],
      swiftSettings: upcomingFeatures
    ),
    .executableTarget(
      name: "Palantir",
      dependencies: ["PalantirInspector", "PalantirNotebookInspector", "PalantirNotebookUI"],
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
      name: "PalantirNotebookInspectorTests",
      dependencies: [
        "PalantirInspector", "PalantirNotebook", "PalantirNotebookInspector", "PalantirNotebookUI",
      ],
      path: "Tests/Notebook/Inspector",
      swiftSettings: upcomingFeatures
    ),
    .testTarget(
      name: "PalantirInspectorTests",
      dependencies: ["PalantirInspector"],
      path: "Tests/Inspector",
      exclude: ["CLI"],
      swiftSettings: upcomingFeatures
    ),
    .testTarget(
      name: "PalantirInspectorCLITests",
      dependencies: ["PalantirInspector", "PalantirInspectorCLI"],
      path: "Tests/Inspector/CLI",
      swiftSettings: upcomingFeatures
    ),
    .testTarget(
      name: "PalantirDriverTests",
      dependencies: ["PalantirDriver"],
      path: "Tests/Driver",
      swiftSettings: upcomingFeatures
    ),
    .testTarget(
      name: "PalantirAcceptanceTests",
      dependencies: ["PalantirAcceptance"],
      path: "Tests/Acceptance",
      exclude: ["Checks", "Fixtures"],
      swiftSettings: upcomingFeatures
    ),
    .testTarget(
      name: "PalantirTests",
      dependencies: [
        "Palantir", "PalantirInspector", "PalantirNotebook", "PalantirNotebookInspector",
        "PalantirNotebookUI",
      ],
      path: "Tests/App",
      swiftSettings: upcomingFeatures
    ),
  ]
)
