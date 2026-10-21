An accepted acceptance check of palantir, a macOS app, failed its replay. You triage it: decide
whether palantir breaks the rule, or the check is wrong.

This folder holds `rule.md` (the rule and its example), `check.json` (the check: a judge from
another family found it faithful to the rule, and it failed against a mutant that breaks the
rule), `format.md` and `cli.md` (the check format and the tools), and the failed replay:
`replay.json` (each step's actions with their exit codes, each expectation with its value, and
where it failed) and `record.json` (every observation). Read them all. Run nothing.

Blame palantir when the replay reached the failing expectation through steps that did what their
lines say, and the observations show palantir doing something the rule's line forbids. Blame the
check when a step did not set up what its line says, or the failing expectation asks for
something the rule does not say. Quote the failing expectation exactly (for a failed action, the failure's message exactly) and the
observed values that decide it, as jq paths into `record.json` with their values as compact JSON. End with the JSON object the output schema asks for.
