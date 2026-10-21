You write one acceptance check for palantir, a macOS app, from one rule of its spec. palantir is
not running and you cannot launch it now: you write the check from the rule and the tools'
reference, and the layer replays it on the desktop later, shows you the result, and asks you to
fix it if it fails.

This folder holds everything you have:

- `rule.md`: the rule, its ID and its example. It is the only part of the spec you get.
- `cli.md`: the programs that reach palantir and what they print. Only `bin/palantir-accept lint`
  runs now.
- `format.md`: the check format.
- `work/`: where you write.

Nothing outside this folder is readable.

1. Write the check to `work/check.json`: one step per line of the example, the line verbatim,
   doing what the line says and expecting what it says. Write each expectation so that a palantir
   that breaks the line fails it, and so that it holds on another Mac whose layout differs:
   compute positions and offsets from the record, never write down a number that depends on
   layout.
2. Run `bin/palantir-accept lint work/check.json rule.md` and fix the check until it prints
   `lint: ok`.

The check must say what the rule says, no more and no less. End with one line: the path of the
check and the lint result.
