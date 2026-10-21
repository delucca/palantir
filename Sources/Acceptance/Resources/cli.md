# The tools that reach palantir

palantir is a macOS app that shows Markdown notebooks. You reach it only through three
programs: `palantir-accept` launches it and replays checks, `palantir-drive` uses it like a
person, and `palantir-inspect` reads what it shows. Nothing else reaches it.

## What the tools show, for every check alike

- The state holds no outline: it does not list which lines are headings or which lines a heading
  owns. Those show only through folding, as `folded` and `drawn` in the state read after a fold
  command.
- A menu item's enabled state is right only while palantir is in front. Read it with
  `palantir-drive activate`, then `menus`, then `restore`; or press it with `menu`, which takes
  the front before it checks the item. Read with palantir in the background, AppKit reports items
  that need a key window as disabled.
- How long layout stays pending after a command depends on the notebook. With a few lines it is
  laid out at once, so a read right after a command and a read a moment later agree whatever
  `wait` does. With thousands of lines a fold command leaves layout pending for a while, and a
  read right after `wait` shows whether `wait` really waited.

## palantir-accept

- `bin/palantir-accept lint <check.json> rule.md` checks a check without palantir: its format, its
  rule's ID, one step per example line verbatim, known actions and jq expressions that compile.
- The layer replays a check with `palantir-accept replay` on the desktop: it launches palantir,
  runs each step, quits palantir and writes `replay.json` (what each step did, each expectation's
  value and the verdict) and `record.json` (every observation). Exit 0 is pass, 1 fail, 2 an error
  before a verdict. You get both files back when a revision needs them.
- A check's `launch` action starts a new palantir behind the person's windows and waits until it
  answers: a debug build with its inspector by default, the release build or no inspector flag
  when the action says so. The replay quits every palantir it launched with
  `palantir > Quit palantir`.

## palantir-drive

```text
usage: palantir-drive [--pid <pid>] <command>

Uses a running palantir like a person, from outside: menu items through the accessibility tree,
keys, clicks and scrolls as system events, sent only while palantir is in front.

  menus                      every menu bar item: path, enabled or disabled, press or not,
                             key equivalent or -
  menu <path>                presses a menu item, such as "View > Fold All"
  key [--system] <chord>...  presses keys, such as cmd+a down shift+pagedown
  type [--system] <text>     types text, a key event per character
  choose <file>              answers the open panel File > Open… shows with an absolute path
  click <x> <y> [--count n]  clicks in window points from the content's top-left corner
  scroll <lines>             scrolls the window's content, down when positive
  capture <out.png>          the window as the screen shows it, title bar included
  tree                       the focused window's accessibility tree
  restore [--to <pid>]       gives the front back to the app a failed command recorded, or to
                             the app with that pid
  activate                   brings palantir to the front and records the app it took it from

Each command that sends input takes the front when another app has it, sends the input, waits
for palantir to take it, and gives the front back on every exit; when giving it back fails it
says so and keeps a record for restore. Keys go to palantir's own queue; key --system,
type --system, click and scroll go through the system's event stream, which reaches whichever
app is in front, and --system refuses Command keys, which could quit, close or hide another
app if they landed late. Without --pid it uses the only palantir running.
```

- `menus` prints one line per menu bar item, tab-separated: its path (titles joined with " > "),
  `enabled` or `disabled`, `press` or `no-press`, and its key equivalent in chord notation such as
  `cmd+o`, or `-` when it has none. It reads the accessibility tree without taking
  the front (see "What the tools show" for what that means for `enabled`). `menu` takes the
  front before it checks the item and presses it.
- Every command that sends input takes the front only for the input and gives it back.
- Exit 1 names the problem, such as a disabled menu item or another window covering a click's
  point. Exit 64 is a usage error.

## palantir-inspect

```text
usage: palantir-inspect [--pid <pid>] <command>

Reads a debug palantir started with --inspector. It never drives the app.

  state                     the window and every feature's state, as JSON
  wait [--timeout <s>]      answers once layout has settled
  screenshot <out.png> [--rect <x,y,width,height>] [--timeout <s>]
                            the window's content at full resolution once layout has
                            settled; the rect is in window points from the content's
                            top-left corner
  list                      the pid and socket of every palantir listening

Without --pid it reads the only palantir listening.
```

Reading never takes the front. Wait after every action before reading. Exit 2 is a socket
problem (most often no palantir listening), exit 1 an inspector error such as layout that did not
settle, exit 64 a usage error.

`state` prints:

```json
{
  "window": { "frame": {"x": 375, "y": 145, "width": 960, "height": 632},
              "content": {"width": 960, "height": 600}, "scale": 2,
              "isActive": true, "isKey": true, "isVisible": true, "isMiniaturized": false },
  "sections": { "notebook": {
    "length": 40,
    "folded": [ {"offset": 6, "line": "## Two"} ],
    "drawn": [ {"offset": 0, "text": "# One", "rect": {"x": 25, "y": 0, "width": 44, "height": 16}},
               {"offset": 6, "text": "## Two", "rect": {"x": 25, "y": 16, "width": 52, "height": 16}},
               {"offset": 30, "text": "# Three", "rect": {"x": 25, "y": 32, "width": 60, "height": 32}} ],
    "gaps": [],
    "markers": [ {"heading": 6, "label": "...", "rect": {"x": 81, "y": 16, "width": 16, "height": 16}} ],
    "selection": {"location": 12, "length": 0},
    "scroll": {"y": 0, "height": 600, "documentHeight": 600} } }
}
```

(The values only illustrate the shape; they say nothing about how palantir behaves.)

- `length`: the text's length in UTF-16 code units, the unit of every offset.
- `folded`: the folded headings, by the offset of their first character, with their line.
- `drawn`: the paragraphs the window shows, top to bottom, each with its first character's offset,
  its text and its rect; the first may start above the window (a negative `y`).
- `gaps`: one entry per two drawn paragraphs in a row that do not touch, such as
  `{"after": 8, "before": 36, "height": 12}`: the offsets of the paragraph above and the one below,
  and the space between them, negative where they overlap. Empty when every paragraph starts where
  the one above it ends.
- `markers`: the folded marker beside each folded heading on screen: the heading's offset, the
  marker's accessibility label and its rect.
- `selection`: the selected range, by offset and length.
- `scroll.y`: the top of the window in the text, in points from the text's top; `height` is the
  window's content height; `documentHeight` is the height the scroller spans.

Coordinates: every rect in a section, the `--rect` of a screenshot and the point of
`palantir-drive click` are window points with the origin at the top-left corner of the window's
content, under the title bar, y growing down. Screenshot pixels are points times `window.scale`.
`window.frame` alone is in screen points from the top-left of the main display.

`screenshot <out.png>` prints `{"path", "width", "height", "scale"}` of the image it wrote. `list`
prints one line per palantir listening: its pid, a tab, and its socket's path.
