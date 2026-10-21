You wrote `work/check.json`, an acceptance check of palantir, from `rule.md`, with `cli.md` and
`format.md`. palantir is not running and cannot be launched now; the layer replays checks on the
desktop and shows you the result.

The check must say what the rule says, no more and no less: one step per line of the example, doing
what the line says and expecting what it says, with expectations that hold whenever the line holds
on any Mac and fail whenever the line does not hold. Never weaken an expectation to make a
replay pass; when palantir may be what breaks the rule, say so in `work/answer.md`.

Run `bin/palantir-accept lint work/check.json rule.md` until it prints `lint: ok`.

---- review
A judge from another model family read the check against the rule and found it unfaithful; its
review is `review.json`. Answer each problem the review names by changing the check, unless the
review is wrong about the rule or the tools; then leave that part and say why in `work/answer.md`,
one line per problem.

End with one line: the lint result and how many problems you fixed and how many you answered.

---- replay
The layer replayed the check and it did not pass. `replay.json` holds what each step did and the
verdict, with the failing step, its phase and the expectation or action that failed; `record.json`
holds every observation. Read what the tools returned, then decide whether the check misread the
tools or the rule, and revise it, or whether palantir does not do what the rule says. In the second
case leave the check as it is and say so in `work/answer.md`.

End with one line: the lint result and whether you changed the check.

---- gate-signal
The layer learned something about the check; `gate-signal.txt` holds it. Act on it by changing the
check.

End with one line: the lint result and what you strengthened.
