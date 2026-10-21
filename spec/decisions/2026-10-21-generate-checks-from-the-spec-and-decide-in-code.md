---
status: accepted
date: 2026-10-21
from: one-pagers/2026-10-21-agents-check-features-against-the-spec
supersedes:
superseded-by:
---
# Generate checks from the spec and let code, not a model, decide

## Context

The acceptance layer has agents check palantir's features against the spec through the running app, and the person writes nothing but the spec. Who decides pass or fail is the choice that outlives the change that adds the layer.

Published evidence is against a model deciding. On AgentRewardBench (1,302 web-agent runs, 12 judges), no model judge passed 70% precision when it called a run a success, while rule-based checkers reached 83.8%; judges most often followed the testing agent's own false claim of success, and vision models miss small offsets and overlaps. palantir's riskiest bugs are layout half a point off, and `palantir-inspect` reports that layout exactly. Tools that run tests written in plain language converge on one split: an AI explores and writes the test once, code replays it and decides (Playwright's test agents, Arbigent, Midscene, Momentic, QA Wolf).

## Decision

- An agent generates each check from one rule's text and example alone, using palantir only through `palantir-drive` and `palantir-inspect`. The check is a generated artifact, a cache of the agent's reading of the example; no person writes, edits or reviews one.
- Replaying a check is code: it drives and reads palantir through the two CLIs and decides pass or fail from what they return. A replay makes no model call, and no model's opinion decides anything the inspector measures.
- A check is accepted only when a judge from another model family than the generating agent's finds it faithful to its rule, and a mutant, a change to palantir that breaks the rule, makes it fail. The review and the mutant run are kept with the check.
- Triage of a failing check ends only as "palantir breaks the rule" or as a replacement check that passes the same gate and fails every mutant the old one failed; it never weakens a check.
- A new or bumped rule gets a newly generated check; a stored check is never patched by hand.
- Model judgment stays only where nothing is measured, and it never gates: exploration findings and screenshot impressions are advisory.

## Rejected

- A model judging every run from the agent's transcript and screenshots: judges call too many runs a success, follow the agent's claims and miss sub-point offsets, and each run would cost minutes of model time and differ from the last.
- A Cucumber-style step library that maps step text to code: the 22 rules use about 70 step phrasings with almost no reuse, and every new phrasing would need code a person writes.
- Acceptance tests written by hand or by the implementing agent: someone writes code per rule, and the implementing agent would check its own reading of the spec.
- promptfoo: a Node dependency and an SDK layer between the run and `claude -p`, with text-only rubrics.
- Inspect AI with inspect_swe: built for Linux sandboxes, with model calls routed through its own provider.
- `claude plugin eval`: sandboxed, with no project configuration and no graders of our own.
- Midscene: vision-only verdicts and one scenario per call.
- TestZeus Hercules: AGPL, and its verdict is whatever its planner says.
- The person reviewing each generated check: the person would be reading code after all, and the judge and the mutant already gate it.

## Consequences

- The person writes only the spec; a check changes only when its rule does or when triage replaces it.
- Replays are cheap and deterministic enough to gate a merge; model cost falls on generation, triage and exploration.
- Every check needs a mutant that breaks its rule, so generating one builds palantir at least twice.
- A check is only as good as what the driver and the inspector expose; a rule whose outcome they cannot report needs inspector work before it gets a check.
- A mutant proves a check catches that one break, not every break, so a weak check can still pass the gate.
- Revisit if model judges match code checks on fine layout, or if generated checks break on ordinary code changes more often than the rules they check.
