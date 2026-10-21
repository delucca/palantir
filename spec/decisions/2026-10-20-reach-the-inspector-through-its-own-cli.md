---
status: accepted
date: 2026-10-20
from: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
supersedes:
superseded-by:
---
# Reach the inspector through a CLI of its own, beside the inspector's code

## Context

decisions/2026-10-20-test-the-running-app-gray-box has agents reach the inspector through a CLI and a skill, and the one-pager asks whether the CLI is its own executable or a palantir subcommand. `inspector.no-release-listener` forbids inspector code in the release executable, and decisions/2026-10-20-organize-sources-tests-and-inspectors-by-feature puts the types the inspector shares with its CLI in `PalantirInspector`.

With every inspector file wrapped in `#if DEBUG`, a release `palantir` held no symbol and no string of the inspector; with one file left unwrapped, 89 of its symbols and its strings were in the release binary although nothing called them. A CLI call for `state` takes about 8 ms. No subcommand was built to compare.

## Decision

- The CLI is its own executable, `palantir-inspect`: the target `PalantirInspectorCLI` in `Sources/Inspector/CLI`, excluded from `PalantirInspector`, and tested by `PalantirInspectorCLITests` in `Tests/Inspector/CLI`. Deleting `Sources/Inspector` deletes the CLI with the inspector.
- It speaks the inspector's JSON-RPC 2.0 over its Unix socket with the types `PalantirInspector` shares, and offers `state`, `wait`, `screenshot` and `list`. It finds the socket by `--pid`, or takes the only palantir listening.
- A release build of it is a stub that says the inspector exists in debug builds only.

## Rejected

- A palantir subcommand, on architecture: the release `palantir` would hold the client's code or answer the subcommand with an error, and the client would live in `App`, which only wires.
- A script around `nc` or Python: it would redo the framing, the error codes and the socket lookup outside the types the inspector compiles against, and drift from them.
- A top-level `Sources/InspectorCLI`: a second folder to delete with the inspector.

## Consequences

- The package has three executables: `palantir`, `palantir-inspect` and `palantir-drive`.
- `PalantirInspector` excludes its `CLI` folder in `Package.swift`, and `PalantirInspectorTests` excludes `Tests/Inspector/CLI`.
- Revisit if the inspector gains a transport the CLI cannot speak, or if a second app needs the same CLI.
