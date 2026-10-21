---
status: accepted
date: 2026-10-20
from: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
supersedes:
superseded-by:
---
# Drive palantir with its own accessibility driver

## Context

decisions/2026-10-20-test-the-running-app-gray-box leaves the outside driver to the change that adds it, and the one-pager suggests Peekaboo. An agent must press every menu item by its path, unattended, send keys that reach palantir only and read the accessibility tree, while the person at the machine keeps working; the user asked that an agent's run take their focus only for the input itself.

Runs on macOS 27.0.1 on 2026-10-20 settled it. Peekaboo 4.9.5's `menu click` returned before the command ran: 0 of 20 Fold All rounds had applied when the state was read as it returned, 20 of 20 only after a second; once it left the View menu open and swallowed every later input; typing into the Open panel failed 2 of 2; and it writes `~/.peekaboo` whatever `HOME` says. `AXPress` on a menu item from a small driver of palantir's own had applied 20 of 20 times when it returned. With palantir inactive, AppKit disables its View items for every tool, since there is no key window, and key equivalents, clicks and scrolls posted to its process do nothing. The Open panel is drawn by another process, so only keys in the system's event stream reach it, and those go to whichever app is in front when the window server delivers them. Its Go to Folder sheet takes neither a path set through accessibility nor `AXConfirm`; a typed path and Return work, 20 of 20.

## Decision

- palantir's driver is its own executable, `palantir-drive` (target `PalantirDriver`), built on the accessibility API (`AXUIElement`) and system events (`CGEvent`) with no third-party code, and built by `swift build` with the app, so there is nothing to download, pin or install.
- It presses menu items by their path with `AXPress` and refuses a disabled one. A press returning is no proof the command ran: the agent reads the state for its effect after every command.
- Keys and typed text go to palantir's own event queue (`CGEvent.postToPid`), so they reach palantir alone.
- Every command that sends input is one scoped operation: it records the app in front, makes palantir the active app (raising its window for clicks, scrolls and captures), sends the input, waits for it to apply, and gives the front back on every exit, failure included, checking it came back. It never takes the front from a third app the person moved to, and it keeps its record until the recorded app is in front again, so `palantir-drive restore` can retry. Menu validation, the key window and the first responder then work as they do for a person.
- Clicks, scrolls and the Open panel's keys go through the system's event stream only while palantir is frontmost with its window on top at the point, checked before each event; each event waits until the system has recorded it, and a click checks that the button is up afterwards.
- The system's event stream carries no Command key: `key --system` refuses every Command chord, and Command-Shift-G exists only inside `choose`, for the Go to Folder sheet.
- `palantir-drive choose <path>` answers the Open panel: Command-Shift-G, the path typed into the sheet's field, Return only when the field holds exactly the path, then the panel's Open button pressed through the accessibility tree until the panel closes.
- A debug launch with the inspector flag starts palantir behind the person's windows without activating it (`open -g`); `just inspect` gives the front back if the launch took it. A normal launch still activates.
- `palantir-drive capture` takes the real window with `screencapture -l`, with the front borrowed like any input.

## Rejected

- Peekaboo: presses that return before the command runs, a menu left open, failed typing in the Open panel, state in the user's home with no setting to move it, and far more than palantir needs (36 MB with an MCP server and an agent).
- System Events through AppleScript or JXA: its menu presses are synchronous, but its keystrokes go to the front app, it needs an Automation grant, and each call costs about 360 ms.
- AXorcist's `axorc` 0.2.2: it presses an item only by its selector identifier, never by its menu path, and sends no input.
- Cua's driver 0.37: it refuses menus in the background, fakes activation through private SkyLight calls, runs a daemon with its own grants and reports telemetry by default.
- XCUIAutomation in Xcode 27.1: it throws outside a UI test bundle.
- Input with palantir left in the background: its menu items are disabled and key equivalents do not run, so the input would not take a person's path. Deferred, not designed.

## Consequences

- palantir maintains the driver and its tests.
- The app the agent runs under needs the Accessibility grant, and Screen Recording for `capture`; neither is tied to palantir's ad-hoc signature, so rebuilds keep them.
- Each input takes the person's focus for under a second and gives it back before the command returns.
- `choose` depends on the macOS Open panel's Go to Folder sheet; a macOS release that changes it breaks the command, and its timeout names the step that failed.
- Checking the front before each event in the system's stream narrows the race with a focus change; nothing outside palantir can close it.
- Revisit if Apple ships UI automation that runs against a SwiftPM macOS app, if a maintained driver passes the same runs, or when input in the background is designed.
