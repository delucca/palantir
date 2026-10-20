---
status: accepted
date: 2026-10-20
from: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
supersedes:
superseded-by:
---
# Test the running app gray-box, with real input from outside and state from a debug-only inspector

## Context

An agent coding palantir cannot open the app, use it, or see what it draws; only in-process tests a person writes check it. Its riskiest bugs are TextKit 2 layout: blank space where hidden text was, a scroller that jumps, a fold marker half a point off. Native macOS has no equivalent of Playwright for the web. An accessibility-tree driver uses an app like a person but sees the notebook as one text area, and screenshots downscaled for a model cannot resolve half a point. Gray-box test frameworks such as EarlGrey, Detox and SBTUITestTunnel pair a driver that uses the app like a person with a test-only channel inside it that reports state and idleness. Nothing packages that for AppKit.

## Decision

- An outside driver does all input to palantir: real system input through the accessibility tree, on the visible window. Which tool is the choice of the change that adds it.
- A debug-only inspector inside palantir reports state, says when layout has settled, and renders full-resolution screenshots, whole or cropped. It never drives: nothing it offers clicks, types, scrolls or runs a command.
- The inspector's state comes from the same measurements the layout tests make, so the two cannot disagree.
- The inspector is compiled only into debug builds and listens only when started with a launch flag, its socket in a private directory. A release build contains no listener.
- Agents reach the inspector through a CLI and a skill in the repo, not an MCP server.
- A feature joins in four steps: every command it adds is a menu bar item, so the driver reaches it with no new driver work; it adds its own section to the inspector's state; each of its custom views has an accessibility label; and it passes the guard test, which fails when a menu command cannot be driven, a feature reports no state, or a custom view has no accessibility label.
- Each later one-pager says in Done when that its feature can be driven and inspected.

## Rejected

- An inspector that also drives, the first design: input through the socket skips the path a person's input takes through key window, first responder and menu validation, so a command could work for an agent and fail for a person.
- An accessibility driver alone: the tree shows the notebook as one text area, blind to folds, gaps and marker positions.
- Claude Code computer use: screenshots downscaled to about 1372x887, one session per machine, the desktop taken over, and no headless runs.
- XCUITest: it needs an Xcode UI test bundle, which a SwiftPM package cannot host.
- An MCP server for the inspector: a registered server loads its tools into every session's context, while a CLI and a skill reach Claude, Codex and agy on demand.
- Commands reachable only by a shortcut or a gesture: each would need its own driver work, and the guard test could not find it.

## Consequences

- Every feature carries the four steps, and a feature that skips one fails the guard test.
- A command with no obvious menu still gets a menu item.
- Driving needs a visible window and an Accessibility grant for the process that runs the driver, so an unattended run shares the desktop with the person; keys sent to an app not in front and App Nap on a covered window are known risks.
- Screenshots rendered inside the app miss Metal content, so once the terminal exists its state comes from its buffer, not its pixels.
- Sharing the layout tests' measurements moves them out of `Tests/`, which decisions/2026-10-20-organize-sources-and-tests-by-feature does not place; where they live is a decision of its own.
- Revisit if real input through the accessibility tree proves unreliable in unattended runs, or if Apple ships UI automation that runs against a SwiftPM macOS app.
