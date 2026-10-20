---
status: accepted
date: 2026-10-20
from:
supersedes:
superseded-by:
---
# Organize the code by feature, with a model target and a UI target per feature

## Context

palantir starts with one feature, notebooks, and will add a terminal, agent sessions and tasks. The package has two targets today, `Palantir` (the AppKit app) and `PalantirCore` (the Markdown outline), and the stack research planned to put sessions, notebooks and models all in `PalantirCore`. In Swift only a target is a boundary: a folder inside a target adds no namespace and no access level, and default actor isolation is set per module, so a feature's main-actor UI and its nonisolated logic cannot share a target. Split by layer at the top, one feature lives in two places, `App/Notebook` and `Notebook`, and deleting one breaks the other. The fold rules also sit inside `NotebookTextView` next to the TextKit layout code, so the notebook's logic can only be tested through a window.

## Decision

- `Sources/` holds `App/` and one folder per feature. A feature folder holds a `Model/` target, with no UI and the default nonisolated isolation, and a `UI/` target, with AppKit and `.defaultIsolation(MainActor.self)`: `Sources/Notebook/Model` is `PalantirNotebook` and `Sources/Notebook/UI` is `PalantirNotebookUI`.
- A feature that wraps a C library adds an engine target and the C target beside them, such as `Terminal/Engine` and `Terminal/CGhostty`, and the engine's API is shaped by what palantir needs, not by the C API.
- `App/` is the executable target `Palantir` and only wires features together: the entry point, the application delegate and the menu bar. Each feature supplies its own menu items.
- A feature's rules live in its model; its UI target does UI work only.
- Target names keep the `Palantir` prefix, so module names stay unique across the dependency graph and never equal a type inside them. Folders drop it through `path:`.
- Each model target has a test target under `Tests/<Feature>/`. Tests that drive a feature through the menu bar or the application delegate live in `Tests/App/`.
- A target is created when its first code arrives, never ahead. UI code that features share gets a shared target once a second feature uses it.
- `App` may import a model target directly; nothing is proxied through a UI target.

## Rejected

- Split by layer at the top (`Sources/App/Notebook` for the UI, `Sources/Notebook` for the logic): one feature in two places, and deleting the feature folder leaves the other one broken.
- A top-level UI folder for every feature: it pays off when several UIs share one core, and palantir has one, the AppKit app.
- One `PalantirCore` library for sessions, notebooks and models: `Core` names a position, not a concept, and one target holding several domains keeps nothing apart.
- One target per layer with a folder per feature inside: Swift folders enforce nothing, so features would reach into each other unchecked.
- Unprefixed target names such as `Notebook` or `Terminal`: they can collide with a dependency's module, or with a type of the same name inside the module.
- Folders only, with no new targets: a main-actor UI and a nonisolated model need separate targets for their default isolation.

## Consequences

- Deleting a feature means deleting its folder and its lines in `Package.swift`.
- What `App` uses from a UI target is marked `package`, such as the notebook's window controller and its fold actions.
- Today's tree does not follow this yet: `Sources/Palantir` and `Sources/PalantirCore` move to `Sources/App` and `Sources/Notebook/{Model,UI}`, the `justfile` copies `Sources/App/Info.plist`, and the fold rules move out of `NotebookTextView` into the notebook model.
- The package has more targets and `package` declarations than one app target would need.
- Revisit if several delivery mechanisms come to share one feature's model, which would argue for a top-level UI folder.
