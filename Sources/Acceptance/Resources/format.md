# The check format

A check is one JSON file that mirrors one rule's example step by step. Code replays it with no
model: it launches palantir, runs each step's actions through `palantir-drive` and
`palantir-inspect`, and decides pass or fail from what they return. A check passes only when
every action exits as expected and every expectation is `true`.

```json
{
  "format": 1,
  "rule": "req~<feature>.<slug>~<version>",
  "example": "<the example's title>",
  "files": { "<name>": "<text>" },
  "steps": [
    { "line": "<one line of the example, verbatim, with its leading '* '>",
      "do": [ <action>, ... ],
      "expect": [ { "that": "<jq expression>", "why": "<what it shows, briefly>" }, ... ] }
  ]
}
```

- `steps` holds one step per line of the example, in order, each with the line verbatim. A
  line's step does what the line says and expects what it says; nothing more.
- `files` are fixtures: each is written fresh into the replay's own folder before the first step.
  A fixture name holds no folder.
- The replay keeps a record, one JSON object. Each action with `"as": "<name>"` stores what it
  observed under that name. The record also holds `files` (fixture name to absolute path), `uid`
  (the user's id) and `pid` (the palantir launched last).
- Every expectation is a jq 1.7 expression over the record; it holds when jq prints exactly
  `true`. Expectations run after the step's actions.

## Actions

Each action is an object with one of these keys, and optionally `"as"` and `"exit"` (the exit
code the action must end with, 0 when left out; any other ends the replay as a fail). `"exit":
"any"` makes an action never fail on its exit code: the exit lands in the record, so `"as"` is
required with it.

An outcome that a Then line claims is asserted in `expect`, never through an action's expected
exit. When the exit code is the outcome, record it with `"exit": "any"` and `"as"`, then assert it
in a jq expression. A non-zero expected exit stays right for setup, in the Given and When steps.

| action | does | stores under `as` |
| --- | --- | --- |
| `{"launch": {"build": "debug" or "release", "inspector": true or false}}` | launches a new palantir; later `drive` and `inspect` actions use it | `{"pid"}` |
| `{"drive": [<argument>, ...]}` | runs `palantir-drive --pid <pid> <arguments>` | `{"exit", "stdout", "stderr"}`, plus `items` for `menus` (`[{"path", "enabled", "press", "key"}]`, `key` being the key equivalent such as `cmd+o`, or `-`) and `elements` for `tree` (`[{"depth", "role", "title", "label", "frame": [x, y, width, height], "actions": [...]}]`) |
| `{"inspect": [<argument>, ...]}` | runs `palantir-inspect --pid <pid> <arguments>` (`list` without `--pid`) | `{"exit", "stdout", "stderr", "json"}` with stdout parsed as JSON, or `sockets` for `list` (`[{"pid", "path"}]`) |
| `{"file": "<fixture name>"}` | reads the fixture on disk | `{"sha256", "size", "mtime"}` |
| `{"stat": <argument>}` | reads a path's metadata, without following a symlink | `{"exists", "mode" (octal text such as "700"), "uid", "isDirectory"}` |
| `{"symbols": "debug" or "release"}` | lists the build's executable's symbols with `nm` | `{"defined": [...], "undefined": [...]}` |
| `{"sleep": <seconds, at most 5>}` | waits | nothing |
| `{"quit": true}` | quits the last palantir launched with its Quit menu item | nothing |
| `{"repeat": [<action>, ...], "until": "<jq expression>", "max": <rounds>}` | runs the actions until the expression is `true`, at most `max` rounds (50 when left out, 200 at most); a fail when it never is | the inner actions' |

An `<argument>` is a string, a number, `{"file": "<fixture name>"}` (the fixture's absolute path),
`{"out": "<name>.png"}` (a new file's path in the replay's folder, for a screenshot; the path is also in the record under `out`, by name) or
`{"jq": "<expression>"}` (the expression's raw output over the record so far). Compute every
coordinate, offset and count that depends on layout from the record with `jq`; never write down a
number that you only saw on this machine.

The replay quits every palantir it launched when it ends, pass or fail.

## Example of the shape

This only shows the syntax; it checks nothing.

```json
{
  "format": 1,
  "rule": "req~example.shape~1",
  "example": "the shape",
  "files": {"n.md": "# One\nText.\n"},
  "steps": [
    {"line": "* Given n.md is open",
     "do": [{"launch": {"build": "debug", "inspector": true}},
            {"drive": ["menu", "File > Open…"]},
            {"drive": ["choose", {"file": "n.md"}]},
            {"inspect": ["wait"]},
            {"inspect": ["state"], "as": "opened"}],
     "expect": [{"that": ".opened.json.sections.notebook.length == 12", "why": "the whole file is shown"}]},
    {"line": "* When the user clicks its first line",
     "do": [{"drive": ["click",
                       {"jq": ".opened.json.sections.notebook.drawn[0].rect | .x + 10"},
                       {"jq": ".opened.json.sections.notebook.drawn[0].rect | .y + .height / 2"}]},
            {"inspect": ["wait"]},
            {"inspect": ["state"], "as": "clicked"}],
     "expect": []}
  ]
}
```
