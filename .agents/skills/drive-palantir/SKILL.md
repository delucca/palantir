---
name: drive-palantir
description: Launches a debug palantir, uses it like a person through its menus, keys and clicks, and reads what it shows (folded headings, drawn lines, gaps, selection, scroll, full-resolution screenshots) from its inspector. Use to check a change in the running app, or to find blank space or a scroller jump after folding. NOT for unit tests (swift test).
---

# Drive and inspect palantir

Two tools, both built into `.build/debug/` with the app. Run everything from the repository root.

- `palantir-drive` uses palantir from outside, the way a person does: it presses menu items through
  the accessibility tree and sends keys, clicks and scrolls as system events, only while palantir is
  the app in front. It reads nothing palantir reports.
- `palantir-inspect` reads what palantir shows from the inspector inside a debug build: state as
  JSON, settled layout, and screenshots. It never clicks, types, scrolls or runs a command, and it
  works with palantir in the background, covered by other windows.

So every step is: act with `palantir-drive`, wait with `palantir-inspect wait`, then read with
`palantir-inspect state` or `palantir-inspect screenshot`, and check that the state shows what the
action should have done. A command that returns has sent its input; only the state says it worked.

The app the shell runs under needs Accessibility, and Screen Recording for `palantir-drive capture`.

## Start and stop

```sh
pid=$(just inspect)        # builds the debug app, launches it in the background, prints its pid
drive() { .build/debug/palantir-drive --pid "$pid" "$@"; }
inspect() { .build/debug/palantir-inspect --pid "$pid" "$@"; }
# ... work ...
drive menu "palantir > Quit palantir"
```

`just inspect` starts palantir behind the person's windows without taking focus. Quit only the
palantir you launched, with its Quit menu item. Never send input to another app with any other
tool.

## Act

The person at this machine keeps working while you drive, so palantir takes the front only for
your input. Each command below does the whole of it: takes the front, sends its input, waits for
palantir to take it, and gives the front back to the app that had it, also when it fails.

- `drive menus` lists every menu item with `enabled` or `disabled`. Every palantir command is a
  menu item, so `drive menu "View > Fold All"` runs it; a disabled item fails with exit 1.
- `drive key <chord>...` presses keys: `cmd+a`, `shift+down`, `pagedown`, `opt+left`.
- `drive type <text>` types text, one key event per character.
- `drive click <x> <y> [--count 2]` clicks a point of the window's content; `drive scroll <lines>`
  scrolls it, down when positive.
- `drive choose <absolute path>` answers the panel File > Open… shows.
- `drive capture <out.png>` captures the window as the screen shows it, title bar included.

If a command says the front did not go back, run `drive restore`: it gives the front back to the
app the failed command recorded.

The notebook is read-only. Left and right move the caret, Option by word, Command and Control-A/E to
the line's ends, Option-up and down to the paragraph's ends, and with Shift each extends the
selection. Up, down, Page Up, Page Down, Home and End scroll without moving the caret. Typing
changes nothing.

To put the selection in a heading, click its line: take the line's `rect` from the state and click
`rect.x + 10`, `rect.y + rect.height / 2`. Then check `selection` in the state.

### Opening a notebook

```sh
drive menu "File > Open…"
drive choose /absolute/path/to/notebook.md
inspect wait
```

`choose` opens the panel's Go to Folder sheet, types the path into its field and sends Return only
once the field holds exactly the path, then presses the panel's Open button through the
accessibility tree, checking each step there before the next. It prints its route on stderr. Then `inspect state` shows the notebook's `length`: check it is the
file's.

## Read

Reading never takes the front: state, waits and screenshots work with palantir behind other
windows. After a long idle in the background they may take a few hundred milliseconds more. A
minimized window cannot settle; `wait` and `screenshot` then fail at once.

- `inspect wait [--timeout s]` answers once the window has no layout or display pending and the
  state has stopped changing. Wait after every action before reading.
- `inspect state` prints the window and one section per feature.
- `inspect screenshot <out.png> [--rect x,y,width,height]` renders the window's content, or the
  rect, at the display's pixels (a 960 by 600 point window is 1920 by 1200 pixels at scale 2).

Coordinates: every rect in a feature's section, and the `--rect` of a screenshot, are window points
with the origin at the top-left corner of the window's content, under the title bar, y growing
down. The same coordinates are what `drive click` takes. Screenshot pixels are points times
`window.scale`. The one exception is `window.frame`: the window's place on the screen, in screen
points from the top-left of the main display.

```json
{
  "window": { "frame": {"x": 375, "y": 145, "width": 960, "height": 632},
              "content": {"width": 960, "height": 600}, "scale": 2,
              "isActive": true, "isKey": true, "isVisible": true, "isMiniaturized": false },
  "sections": { "notebook": {
    "length": 44,
    "folded": [ {"offset": 8, "line": "## Fix the reaper"} ],
    "drawn": [ {"offset": 0, "text": "# Tasks", "rect": {"x": 25, "y": 0, "width": 56, "height": 16}},
               {"offset": 8, "text": "## Fix the reaper", "rect": {"x": 25, "y": 16, "width": 137, "height": 16}},
               {"offset": 36, "text": "# Notes", "rect": {"x": 25, "y": 32, "width": 56, "height": 32}} ],
    "gaps": [],
    "markers": [ {"heading": 8, "label": "Folded", "rect": {"x": 166, "y": 16, "width": 16, "height": 16}} ],
    "selection": {"location": 12, "length": 0},
    "scroll": {"y": 0, "height": 600, "documentHeight": 600} } }
}
```

- `folded`: the folded headings, by the UTF-16 offset of their first character.
- `drawn`: the paragraphs the window shows, top to bottom; the first one may start above the
  window (a negative `y`). These are what the layout tests measure.
- `gaps`: two drawn paragraphs with space between them (`height` > 0) or overlapping (< 0). Empty
  when every paragraph starts where the one above it ends.
- `markers`: the folded marker beside each folded heading on screen.
- `scroll.y`: how far the text is scrolled, in text points; `height` is the window's content
  height; `documentHeight` is the height the scroller spans.

## Checking a fold

Pick the anchor before the command: the heading you fold, or the top drawn line when the fold is
above it. Save the state and a crop around the anchor before and after the command.

- A scroller jump is the anchor moving on screen, and only that: its `rect.y` before and after
  differ. A change of `scroll.y` with the anchor's `rect.y` the same is the text moving under a
  still window, as a fold above the window does; it is not a jump.
- Blank space where hidden text was is an entry in `gaps`, or in a crop a drawn line that does not
  start at the bottom of the one above it.
- Blank space below the text needs three numbers:
  - The text's extent: the last paragraph's bottom, `rect.y + rect.height + scroll.y` of the last
    drawn line when that line ends the text.
  - The fold floor, which palantir keeps on purpose. A fold or unfold command (or a width change)
    that leaves the text ending above the window's bottom, with the anchor below the document's
    top, stores the anchor's top: the `scroll.y` right after that command. The document then stays
    at least that top plus `height` tall, so the anchor stays put. Scrolling does not change the
    stored top; the next fold command or width change sets it again, and opening a notebook drops
    it. So note `scroll.y` and the text's extent right after every fold command: when the text
    ended above `scroll.y + height` then, the floor is that `scroll.y + height`, whatever the window
    shows later; otherwise there is none.
  - The upper bound: `documentHeight` is never more than the text's extent plus one `height`.
  Blank space below the text is a defect only when `documentHeight` is more than both the text's
  extent and the floor, or more than the upper bound, which holds even when you did not see the
  command that set the floor.

Back each claim with the state values and a screenshot crop of the lines around it.

## When something fails

- `palantir-drive` exit 1 names the problem, such as a disabled menu item, another window covering
  the point of a click, or the front not going back. Exit 64 is a usage error.
- `palantir-inspect` exit 2 means no palantir is listening: launch one with `just inspect`. Exit 1
  is an inspector error, such as layout that did not settle within the timeout and what was pending.
