---
status: approved
date: 2026-10-21
---
# Agents check palantir's features against the spec through an acceptance layer

## Problem

Every rule has integration tests, but the agent that wrote the code also wrote them, so they check its own reading of the spec, and they press menu items inside the test process, a path no person takes. The real app was checked once, by hand.

A model judging pass or fail is no fix: judges of web agents call too many runs a success, believe the testing agent's claims, and miss offsets of a point, which is what palantir's folding bugs look like. No tool runs rules like palantir's against a native macOS app.

## Solution sketch

An acceptance layer. For each rule's example, an agent reads only the spec, uses the running app through `palantir-drive` and `palantir-inspect` as a person would, and saves what it did and saw as a generated check: a cache of its reading, step by step. Code replays the check and decides from the inspector's state, so no model rules on what the inspector measures. The person writes only the spec; nobody writes, edits or reviews a check, and a check reaches palantir only through the two CLIs.

A check is accepted only after a judge from another model family reads it against the rule and a mutant, a change to palantir that breaks the rule, makes it fail. A failing check goes to triage, which blames the app or fixes the check through the same gate, and never loosens it.

Every rule is tried, outline rules through folding and the release rule through a release build, except the inspector's checks on itself.

Replaying gates a merge that touches a rule, and a check is generated when a rule is added or bumped. Before a release, exploration has agents try variations around each rule and report spec gaps without failing the run. Runs use the person's Mac, and an isolated macOS machine for releases, for palantir only.

## Done when

- `just test-acceptance` replays a check for every rule but the inspector's checks on itself, with a verdict per rule ID.
- A new or bumped rule gets a check generated from the spec, with no code written by a person.
- Every accepted check fails against its mutant, with the review and the mutant run kept.
- Breaking a rule on purpose fails its check, and triage blames the app, not the check.
- An exploration run reports candidate spec changes and fails nothing.
- The layer runs on the person's Mac and on an isolated macOS machine.

## Open questions

- What format does a check take? No standard exists; the candidate mirrors the example step by step, replayed by one generic suite. Deferred to the change that adds the layer.
- Which isolated machine: a Tart macOS 27 VM, where the Accessibility grant is the risk, or a cloud Mac? Deferred to a spike in that change.
- Which model families generate and judge, and how does a check cite its rule for lint and trace? Deferred to that change.
