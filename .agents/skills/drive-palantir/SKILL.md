---
name: drive-palantir
description: Launches a debug palantir with just inspect, uses it like a person through its menus, keys and clicks with palantir-drive, and reads what it shows (folded headings, drawn lines, gaps, selection, scroll, full-resolution screenshots) with palantir-inspect. Use to try a change in the running app, to screenshot palantir, or to find blank space or a scroller jump after folding. NOT for the test suites (swift test, just test, just test-desktop).
---

# Drive and inspect palantir

Two tools, both built into `.build/debug/` with the app. Run everything from the repository root.

- `palantir-drive` uses palantir from outside, the way a person does: it presses menu items through
  the accessibility tree, posts keys and text to palantir's own event queue, and sends clicks and
  scrolls through the system's event stream, all only while palantir is the app in front. It reads
  nothing palantir reports.
- `palantir-inspect` reads what palantir shows from the inspector inside a debug build: state as
  JSON, settled layout, and screenshots. It never clicks, types, scrolls or runs a command, and it
  works with palantir in the background, covered by other windows.

So every step is: act with `palantir-drive`, wait with `palantir-inspect wait`, then read with
`palantir-inspect state` or `palantir-inspect screenshot`, and check that the state shows what the
action should have done. A command that returns has sent its input; only the state says it worked.

The app the shell runs under needs Accessibility, and Screen Recording for `palantir-drive capture`.

## Start and stop

```sh
just inspect      # builds the debug app, launches it in the background, prints its pid
```

`just inspect` starts palantir behind the person's windows without taking focus. When it exits
non-zero, read its stderr before using a pid it printed: a palantir that did not settle was
terminated.

Each shell command may start a fresh shell, so carry no variable or function from one to the next:
write the pid into every command. Below, `drive` stands for `.build/debug/palantir-drive --pid
<pid>` and `inspect` for `.build/debug/palantir-inspect --pid <pid>`; spell both out each time.

Stop with `drive menu "palantir > Quit palantir"`. Quit only the palantir you launched, with its
Quit menu item. Never send input to another app with any other tool.

## Act

The person at this machine keeps working while you drive, so palantir takes the front only for
your input. Each command below does the whole of it: takes the front, sends its input, waits for
palantir to take it, and gives the front back to the app that had it, also when it fails.

- `drive menus` lists every menu item, one per line and tab-separated: its path, `enabled` or
  `disabled`, and `press` or `no-press`. Every palantir command is a menu item, so
  `drive menu "View > Fold All"` runs it; a disabled item fails with exit 1.
- `drive key <chord>...` presses keys: `cmd+a`, `shift+down`, `pagedown`, `opt+left`.
- `drive type <text>` types text, one key event per character.
- `drive click <x> <y> [--count 2]` clicks a point of the window's content; `drive scroll <lines>`
  scrolls it, down when positive.
- `drive choose <absolute path>` answers the panel File > Open… shows.
- `drive capture <out.png>` captures the window as the screen shows it, title bar included. It
  takes the front and needs Screen Recording, so use it only when the title bar or what the screen
  really shows matters; take every other picture with `inspect screenshot`.

If a command says the front did not go back, run `drive restore`: it gives the front back to the
app the failed command recorded.

The notebook is read-only. Left and right move the caret, Option by word, Command and Control-A/E to
the line's ends, Option-up and down to the paragraph's ends, and with Shift each extends the
selection. Up, down, Page Up, Page Down, Home and End scroll without moving the caret. Typing
changes nothing.

To put the selection in a heading, click its line: take the line's `rect` from the state and click
`rect.x + 10`, `rect.y + rect.height / 2`. Then check that `selection.location` in the state is in
that line, from its `offset` up to the next drawn line's. The fold commands read only the location,
so a `length` of 1, which a click can leave, is fine.

### Opening a notebook

```sh
drive menu "File > Open…"
drive choose /absolute/path/to/notebook.md
inspect wait
```

`choose` types the path into the panel's Go to Folder sheet and presses Open, checking each step in
the accessibility tree, and prints its route on stderr. Then check that `length` in `inspect state`
is the file's: it counts UTF-16 code units, like every offset, so for an ASCII file it is `wc -c`.

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
- `gaps`: one entry per two drawn paragraphs in a row that do not touch, such as
  `{"after": 8, "before": 36, "height": 12}`: the offsets of the paragraph above and the one below,
  and the space between them, negative where they overlap. Empty when every paragraph starts where
  the one above it ends.
- `markers`: the folded marker beside each folded heading on screen.
- `scroll.y`: the top of the window in the text, in points from the text's top; `height` is the
  window's content height; `documentHeight` is the height the scroller spans.

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
  - The fold floor, which palantir keeps on purpose so the anchor stays put. A fold or unfold
    command that leaves the window below the text's top (`scroll.y` above 0) and the text ending
    above the window's bottom (`scroll.y + height`) stores the window's top: the `scroll.y` right
    after that command. The floor is that stored top plus `height`, and the document stays at least
    that tall. Scrolling keeps the stored top. The next fold command sets it again or drops it, a
    width change moves or drops it but never sets one, and opening a notebook drops it. So note
    `scroll.y` and the text's extent right after every fold command; with no stored top there is
    no floor.
  - The upper bound: `documentHeight` is never more than the text's extent plus one `height`.
  The document is never shorter than the window either. So blank space below the text is a defect
  only when `documentHeight` is more than the largest of the text's extent, `height` and the floor,
  or more than the upper bound, which holds even when you did not see the command that set the
  floor.

Back each claim with the state values and a screenshot crop of the lines around it.

## When something fails

- `palantir-drive` exit 1 names the problem, such as a disabled menu item, another window covering
  the point of a click, or the front not going back. Exit 64 is a usage error, for both tools.
- When `palantir-drive` fails because palantir left the front during the input, the person switched
  apps and part of the input may not have been sent: read the state, then run the command again.
  Leave `palantir-drive activate` alone: it keeps the front until a `restore`.
- `palantir-inspect` exit 2 is a socket problem, which its message names: most often no palantir
  listening, so launch one with `just inspect`. Exit 1 is an inspector error, such as layout that
  did not settle within the timeout and what was pending.
