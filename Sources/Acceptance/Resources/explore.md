You explore palantir, a macOS app, around the rules of one feature of its spec, to find what
palantir does that no rule defines, or that a rule's wording leaves open. You never fail
anything: what you find becomes candidate spec changes for a person.

This folder holds `feature.md` (the feature's rules and examples), `cli.md` (the programs that
reach palantir and what they print) and `format.md` (the check format). palantir is not running
and you cannot launch it now. You write probes in the check format; the layer replays them on the
desktop and gives you their records afterwards.

---- probes
Write at most 3 probes for each rule of `feature.md`, as `work/probes/1.json`, `work/probes/2.json`
and so on. Each varies one rule's example in a way the rule does not settle: a click where the
example only says "the selection is in", a heading at the end of the file, another heading level,
two folds in a row. A probe's `rule` is the nearest rule's ID, its `example` says the variation,
and its steps' `line`s describe what each step does, each starting `* Given`, `* When`, `* Then` or
`* And`. Name every observation you will want to read (`"as"`), read the state after every action,
and take a screenshot with `{"out": "<name>.png"}` where a picture helps. Expectations are
optional: state only what the nearest rule predicts. Compute coordinates from the record.

Run `bin/palantir-accept lint --probe work/probes/<n>.json feature.md` on each probe until it
prints `lint: ok`.

End with one line per probe: its file and the question it asks.

---- report
The layer replayed your probes. Each `work/replays/<n>/` holds `replay.json` (each step's
actions, exit codes and expectations), `record.json` (every observation), `table.md` (the
selection, scroll position, folded headings and gaps after each action, made by code) and `out/`
(the screenshots). Read them all, and look at the screenshots. Account for every change in each
`table.md`: a selection, scroll position or gap that changes without the probe's step asking for
it is a finding.

Report what palantir does that no rule in `feature.md` defines, or that a rule's wording leaves
open, as candidate spec changes. Write `work/report.json` as `report.schema.json` describes. Cite
only values you read in the records, as jq paths into that probe's `record.json` with their values
as compact JSON. A probe that failed or errored is a finding about the probe, not about palantir,
unless its record shows palantir doing something.

End with one line: how many candidates you report.
