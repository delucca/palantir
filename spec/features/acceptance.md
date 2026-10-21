# Feature: Acceptance

Checks palantir against its feature rules through the running app, with checks that agents generate from the spec and code replays.

## Rule: When a rule has no check, or a newer version than its check, the acceptance layer shall generate a check for it from the rule's text and example alone
`req~acceptance.generate~1`
From: one-pagers/2026-10-21-agents-check-features-against-the-spec

### Example: a bumped rule
* Given the check of heading-folding.fold was generated for version 1
* And heading-folding.fold is now at version 2
* When the acceptance layer generates checks
* Then heading-folding.fold gets a new check for version 2
* And the agent that generated it was given only the rule's text and example, palantir-drive and palantir-inspect

## Rule: Replaying a check shall use palantir only through palantir-drive and palantir-inspect, and shall decide pass or fail from what they return, with no model call
`req~acceptance.replay~1`
From: one-pagers/2026-10-21-agents-check-features-against-the-spec
Decided in: decisions/2026-10-20-test-the-running-app-gray-box

### Example: replaying the fold check
* Given an accepted check for heading-folding.fold
* When just test-acceptance replays it
* Then its verdict is pass
* And the replay made no model call
* And no step of it reached palantir except through palantir-drive and palantir-inspect

## Rule: The acceptance layer shall report one verdict per rule ID for every rule in the feature files, except inspector.notebook-state and the rules of this feature, whose outcomes only palantir's own process or the layer itself can report
`req~acceptance.every-rule~1`
From: one-pagers/2026-10-21-agents-check-features-against-the-spec

### Example: today's rules
* When just test-acceptance runs
* Then it reports one verdict for each rule ID in spec/features
* And it reports none for inspector.notebook-state or for any acceptance rule

## Rule: A generated check shall be accepted only after a judge from another model family than the generating agent's finds it faithful to its rule, and a mutant of palantir that breaks the rule makes the check fail
`req~acceptance.gate~1`
From: one-pagers/2026-10-21-agents-check-features-against-the-spec

### Example: the gap check
* Given a check generated for heading-folding.no-gap
* And a mutant of palantir that leaves blank space where folded text was
* When the check is gated
* Then a judge from another model family reads the check against the rule and finds it faithful
* And the check fails against the mutant
* And the judge's review and the mutant run are kept with the check

## Rule: When a check fails, triage shall report either that palantir breaks the rule or that the check is wrong, and a check it puts in place shall pass the gate and fail every mutant the old check failed
`req~acceptance.triage~1`
From: one-pagers/2026-10-21-agents-check-features-against-the-spec

### Example: a broken fold
* Given an accepted check for heading-folding.fold
* And palantir built with Fold Heading leaving no folded marker
* When just test-acceptance replays the check and it fails
* Then triage reports that palantir breaks heading-folding.fold
* And the check is unchanged

## Rule: An exploration run shall try variations around each rule and report what it finds as candidate spec changes, and shall never fail
`req~acceptance.exploration~1`
From: one-pagers/2026-10-21-agents-check-features-against-the-spec

### Example: a behavior no rule defines
* Given a click on a heading leaves a one-character selection, which no rule defines
* When an exploration run explores heading-folding
* Then it reports the one-character selection as a candidate spec change, with the state and screenshots that show it
* And the run succeeds

## Rule: The acceptance layer shall run the same checks on the person's Mac and on an isolated macOS machine, with the same verdicts for the same build
`req~acceptance.machines~1`
From: one-pagers/2026-10-21-agents-check-features-against-the-spec

### Example: one build on both machines
* Given one build of palantir
* When just test-acceptance runs on the person's Mac and on the isolated macOS machine
* Then both report the same verdict for every rule
* And the run on the isolated machine sends no input to the person's Mac
