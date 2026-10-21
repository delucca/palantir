You review one acceptance check of palantir, a macOS app, against the rule it checks. A model of
another family wrote the check from the rule and the tools' reference alone; code replays it with
no model, and it gates merges, so a check that is weaker or stronger than its rule is a defect.

This folder holds `rule.md` (the rule, its ID and its example), `check.json` (the check),
`format.md` (the check format: each action, what it records, how expectations are decided) and
`cli.md` (the tools the actions run and what they print). Read all four. Run nothing else.

For each line of the example, decide whether its step is faithful:
- it does what the line says, through the actions, and sets up nothing the line does not say;
- its expectations hold when the line holds, on any Mac: nothing depends on one machine's layout
  numbers, timing or display;
- they fail when the line does not hold: a palantir that breaks the line fails the step;
- they check nothing the rule does not say.

Judge the check against the example as it is written: its Given lines set up the situation they
name in palantir's own window, and a check need not guard against a layout in which that
situation could not be set up at all.

Mark each problem `blocking` when it lets a palantir that breaks a line pass, or fails a palantir
that keeps every line in the example's own situation; mark it `advisory` otherwise. The check is
faithful when no problem is blocking.

A problem is blocking only if a check written with the same two tools, as `cli.md` documents them,
could have avoided it. What those tools cannot observe at all, such as access lists on a folder, an
object that exists only between two samples, an item the accessibility tree does not expose, or a
title other than the one exposed, is a limit of the rule or of the instruments: list it as
advisory, never blocking. A check that misses something the tools do expose stays blocking, such as
comparing only the paragraphs in the window when scrolling or the text length could have caught the
difference.

Judge the check for the situation it sets up itself: its own fixture files as written, in palantir's
window at the size and scale the state reports. A problem that arises only with another fixture,
another window size, or text and wrapping that the fixture does not contain is advisory. A gap the
tools can observe within the check's own situation stays blocking, such as samples that can skip
text between two scrolls of the check's own fixture. Report each problem with the line it is in and the
expression or action at fault. End with the JSON object the output schema asks for.
