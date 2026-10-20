---
status: draft
date: 2026-10-20
---
# Let AI agents drive and inspect the running app

## Problem

palantir's riskiest behavior is TextKit 2 folding: blank space left where hidden text was, a scroller that jumps, a fold marker out of place. Only in-process tests a person writes can check it today. An agent coding palantir cannot open the app, use it, or see what it draws.

Claude Code's computer use sees only downscaled screenshots and takes over the desktop. An accessibility-tree driver uses the app like a person, but sees the notebook as one text area, blind to folds and to a marker half a point off.

## Solution sketch

Gray-box testing, as in EarlGrey and Detox: an outside driver uses palantir with real system input, and a debug-only inspector inside it reports what the app shows.

The driver is an accessibility-tree tool on the visible window; Peekaboo is the suggestion. Hiding the window is worth trying, not required. Every command lives in the menu bar, so a new command needs no driver work.

The inspector reports state (folded headings, drawn lines and their positions, gaps, selection, scroll position), says when layout has settled, and renders full-resolution screenshots, whole or cropped. State comes from the measurements the layout tests use. Each feature adds its own state, and later one-pagers say in Done when that their feature can be driven and inspected. The inspector never drives the app. Suggested shape: a Unix socket speaking JSON-RPC 2.0, one message per line, behind a small Swift CLI.

The inspector exists only in debug builds started with a launch flag, its socket in a private directory. There is no MCP server. A skill in the repo teaches the loop to Claude, Codex and agy.

Known risks: keys sent to an app not in front, App Nap on a covered window, and Metal content missing from rendered screenshots once the terminal exists.

## Done when

- An agent launches palantir and uses every menu command and keyboard action through real input, unattended.
- The folds, drawn lines, gaps and scroll position an agent reads match what the layout tests measure.
- An agent can wait for settled layout and get full-resolution screenshots, whole or cropped.
- A release build contains no listener.
- A test fails when a menu command cannot be driven, a feature reports no state, or a custom view has no accessibility label.
- An agent given only the skill folds and unfolds a real notebook and reports, from state and screenshots, whether blank space or a scroller jump appeared.

## Open questions

- Which driver? Deferred to the change that adds it.
- Does palantir need its own ScreenCaptureKit capture, and so a self-signed certificate, now that the driver captures the real window? Deferred to the same change.
- Is the CLI its own executable or a palantir subcommand? Deferred to the change that adds the inspector.
- Moving the layout probes out of Tests/ touches the organize-by-feature decision. Deferred to a decision.
