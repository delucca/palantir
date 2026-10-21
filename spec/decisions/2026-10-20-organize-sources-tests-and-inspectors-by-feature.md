---
status: superseded
date: 2026-10-20
from: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
supersedes: decisions/2026-10-20-organize-sources-and-tests-by-feature
superseded-by: decisions/2026-10-20-organize-sources-tests-inspectors-and-the-driver-by-feature
---
# Organize the code and its tests by feature, with model, UI and inspector targets per feature

## Context

palantir starts with one feature, notebooks, and will add a terminal, agent sessions and tasks. The package has two targets today, `Palantir` (the AppKit app) and `PalantirCore` (the Markdown outline), and the stack research planned to put sessions, notebooks and models all in `PalantirCore`. In Swift only a target is a boundary: a folder inside a target adds no namespace and no access level, and default actor isolation is set per module, so a feature's main-actor UI and its nonisolated logic cannot share a target. Split by layer at the top, one feature lives in two places, `App/Notebook` and `Notebook`, and deleting one breaks the other. The fold rules also sit inside `NotebookTextView` next to the TextKit layout code, so the notebook's logic can only be tested through a window.

decisions/2026-10-20-test-the-running-app-gray-box adds a debug-only inspector that reports each feature's state from the same measurements the layout tests make. Those measurements sit in `Tests/App/LayoutProbes.swift`, where only tests reach them, and they read `NotebookTextView` internals through `@testable`. The layout had no place for the inspector, which is neither a feature nor wiring.

## Decision

- `Sources/` holds `App/`, `Inspector/` and one folder per feature. A feature folder holds a `Model/` target, with no UI and the default nonisolated isolation, and a `UI/` target, with AppKit and `.defaultIsolation(MainActor.self)`: `Sources/Notebook/Model` is `PalantirNotebook` and `Sources/Notebook/UI` is `PalantirNotebookUI`.
- A feature that reports state adds an `Inspector/` target beside them, with AppKit and `.defaultIsolation(MainActor.self)`, depending on its UI target: `Sources/Notebook/Inspector` is `PalantirNotebookInspector`. It holds the feature's layout probes, the read-only measurements its tests and the inspector share, and its state section.
- `Sources/Inspector` is `PalantirInspector`: the listener, the settled-layout check, the screenshots and the types the inspector shares with its CLI. It imports no feature; a feature's `Inspector/` target may import it for what a state section needs.
- Neither kind of inspector target puts code in a release build.
- Helpers that move the view, such as scrolling to an offset, stay in the tests, because the inspector never drives.
- A feature that wraps a C library adds an engine target and the C target beside them, such as `Terminal/Engine` and `Terminal/CGhostty`, and the engine's API is shaped by what palantir needs, not by the C API.
- `App/` is the executable target `Palantir` and only wires features and the inspector together: the entry point, the application delegate, the menu bar and, in debug builds, the inspector. Each feature supplies its own menu items and its own state section.
- A feature's rules live in its model; its UI target does UI work only, and its `Inspector/` target only measures and reports.
- Target names keep the `Palantir` prefix, so module names stay unique across the dependency graph and never equal a type inside them. Folders drop it through `path:`.
- Every source target gets a test target at the same path under `Tests/`: `Tests/Notebook/Model` is `PalantirNotebookTests` and `Tests/Notebook/UI` is `PalantirNotebookUITests`. Tests that drive a feature through the menu bar or the application delegate stay in `Tests/App/`, which is `PalantirTests`.
- A target is created when its first code arrives, never ahead. UI code that features share, probes included, gets a shared target once a second feature uses it.
- `App` may import a model target directly; nothing is proxied through a UI target.

## Rejected

- Split by layer at the top (`Sources/App/Notebook` for the UI, `Sources/Notebook` for the logic): one feature in two places, and deleting the feature folder leaves the other one broken.
- A top-level UI folder for every feature: it pays off when several UIs share one core, and palantir has one, the AppKit app.
- One `PalantirCore` library for sessions, notebooks and models: `Core` names a position, not a concept, and one target holding several domains keeps nothing apart.
- One target per layer with a folder per feature inside: Swift folders enforce nothing, so features would reach into each other unchecked.
- Unprefixed target names such as `Notebook` or `Terminal`: they can collide with a dependency's module, or with a type of the same name inside the module.
- Folders only, with no new targets: a main-actor UI and a nonisolated model need separate targets for their default isolation.
- Probes in the feature's UI target: no `package` surface, but measuring code would sit in the target that draws, and only a target keeps the two apart.
- One shared probes target for every feature: it cuts across features, the same grab-bag as `PalantirCore`.
- Probes left in `Tests/`: the inspector cannot reach them, and a second copy for it would drift from what the tests measure.
- The inspector inside `App`: `App` would stop being only wiring, and a separate CLI could not share the inspector's types without importing the executable.

## Consequences

- Deleting a feature means deleting its folders under `Sources/` and `Tests/`, its lines in `Package.swift`, and its wiring and tests in `App`.
- Removing the inspector means deleting `Sources/Inspector`, each feature's `Inspector/` folder, their tests, their lines in `Package.swift` and their wiring in `App`.
- What `App` uses from a UI target is marked `package`, such as `NotebookWindowController`'s `init()`, `makeFileMenuItems()`, `makeViewMenuItems()` and `openDocument(_:)`.
- What a feature's `Inspector/` target reads from its UI target is marked `package` too, such as `NotebookTextView`'s `folds`, `laidOut`, `foldedMarkers` and `markerGap`.
- The probes drop Swift Testing's `#require`, which belongs in test targets, and throw plain errors; the layout tests import them from `PalantirNotebookInspector`.
- `App`'s delegate keeps a one-line `openDocument(_:)` forward to the notebook controller. AppKit's responder chain reaches the controller only while its window is key or main, so without the forward File > Open is disabled when the window is minimized.
- The package has more targets and `package` declarations than one app target would need, and a feature that reports state has three.
- Revisit if several delivery mechanisms come to share one feature's model, which would argue for a top-level UI folder, or if a feature's `Inspector/` target ends up as little more than `package` forwards into its UI target.
