---
status: accepted
date: 2026-10-21
from: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
supersedes:
superseded-by:
---
# Split the tests into four layers chosen by an env var, with the layer code in one test-support target

## Context

The suite had two recipes: `just test`, which skipped the tests that launch palantir, and `just test-desktop`, which ran everything plus those. Neither meant all tests or one kind of test. A test that launches palantir takes the person's focus for about a second, and agents run `swift test` often while the person works.

Swift Testing tags are the natural way to group tests, but Swift 6.4's `swift test --filter tag:` reads the argument as a test-name pattern, matches nothing and exits 0. Tag filtering exists only on swift-testing's main branch, in no release.

Each SwiftPM test target is its own module, so code every test target uses needs a target of its own or a copy in each. decisions/2026-10-20-organize-sources-tests-inspectors-and-the-driver-by-feature places a test target beside each source target and rejects a shared probes target as a grab-bag across features, but says nothing about code that only tests share.

## Decision

- There are four layers. Unit is pure logic, with no window, socket or process. Integration uses real AppKit windows and views, or real sockets, inside the test process. E2e launches palantir as a process of its own, which can take the front. Release checks a release build.
- `PALANTIR_TEST_LAYERS` names the layers to run, comma-separated. Unset, every layer but e2e runs, so a bare `swift test` never takes the person's focus. An unknown or empty value fails the run instead of skipping every test.
- Every suite carries one layer through a condition trait, `@Suite(.layer(...))`. Every test that launches palantir lives in the one serialized e2e suite, so two launches never overlap.
- `just test` runs all four layers, and `just test-unit`, `just test-integration`, `just test-e2e` and `just test-release` run one each.
- The layer code lives once, in a test-support library target `PalantirTestLayers` at `Tests/Layers` that every test target depends on. Swift Testing allows importing Testing into a library meant for test targets. The target holds only the layers, never other test helpers.
- A guard test fails when a suite carries no layer or a test sits outside a suite.

## Rejected

- Swift Testing tags: Swift 6.4's `swift test` cannot filter by tag, and the support exists only on swift-testing's main branch.
- A development-snapshot toolchain to get tag filtering: every build on every machine would use an unreleased compiler, for a convenience.
- Splitting by cost: measured, every layer but e2e runs in seconds, so cost separates almost nothing; the tests that cost something are the ones that take focus.
- One test target per layer, filtered by target name: a test's layer would follow from where it lives, which breaks the per-feature test layout.
- One parameterized `just test` recipe: a named recipe per layer was chosen as the interface.
- Seven identical copies of the layer code kept in step by a guard test: every rule change means seven edits, and drift is caught only after it happens.
- A general test-support target for any helper tests share: the grab-bag the layout decision rejects for probes.

## Consequences

- A new test target depends on `PalantirTestLayers`, and a new suite picks a layer or fails the guard test.
- A new layer means a case in `PalantirTestLayers`, its recipe, and adding it to `just test`'s list.
- The e2e tests run only under `just test` or `just test-e2e`; a bare `swift test` skips them.
- A run of one layer prints every test outside it as skipped.
- The code on main at 8e0454b still holds seven identical `Layer.swift` copies; moving them into `PalantirTestLayers` is pending work.
- Revisit if a Swift release ships tag filtering in `swift test`, which would replace the condition trait with tags, or if `PalantirTestLayers` starts collecting helpers beyond the layers.
