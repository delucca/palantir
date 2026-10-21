# Feature: Inspector

Reports what palantir shows to an agent that drives it from outside, in debug builds only, and never drives it.

## Rule: The inspector shall listen only in a debug build started with the inspector launch flag, on a socket in a directory only the user can open
`req~inspector.debug-only~1`
From: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
Decided in: decisions/2026-10-20-test-the-running-app-gray-box

### Example: a debug build with and without the flag
* When a debug build of palantir launches without the inspector launch flag
* Then it creates no inspector socket
* When it launches again with the flag
* Then it answers on a socket in a directory only the user can open

## Rule: A release build of palantir shall contain no inspector code and no listener
`req~inspector.no-release-listener~1`
From: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
Decided in: decisions/2026-10-20-test-the-running-app-gray-box
Decided in: decisions/2026-10-20-organize-sources-tests-and-inspectors-by-feature

### Example: a release build
* When palantir is built for release
* Then its executable holds no code from an inspector target
* And launching it with the inspector launch flag creates no socket

## Rule: The inspector shall report the notebook's folded headings, the lines drawn in the window with their positions, the gaps between drawn lines, the selection and the scroll position, as the layout tests measure them
`req~inspector.notebook-state~1`
From: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
Decided in: decisions/2026-10-20-test-the-running-app-gray-box

### Example: a folded task
* Given a notebook with the lines "# Tasks", "## Fix the reaper", "It leaks." and "# Notes" is open
* And "## Fix the reaper" is folded
* When an agent asks the inspector for the notebook's state
* Then it lists "## Fix the reaper" as folded
* And it lists the drawn lines "# Tasks", "## Fix the reaper" and "# Notes", each at the position the layout probes measure
* And it reports no gap between them
* And the selection and scroll position it reports are the view's

## Rule: The inspector's state shall hold a section for every feature palantir wires in
`req~inspector.state-per-feature~1`
From: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
Decided in: decisions/2026-10-20-test-the-running-app-gray-box
Decided in: decisions/2026-10-20-organize-sources-tests-and-inspectors-by-feature

### Example: today's features
* Given palantir wires in the notebook feature
* When an agent asks the inspector for its state
* Then the state holds a notebook section

## Rule: When an agent waits for settled layout, the inspector shall answer only once the window has no layout or display pending
`req~inspector.settled-layout~1`
From: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
Decided in: decisions/2026-10-20-test-the-running-app-gray-box

### Example: waiting after Fold All
* Given a notebook taller than the window is open
* When the user chooses View > Fold All and an agent at once waits for settled layout
* Then the wait answers after the fold's layout
* And the state read right after it matches the state read a second later

## Rule: The inspector shall render the window's content at the display's full resolution, whole or cropped to a rectangle given in window points
`req~inspector.screenshots~1`
From: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
Decided in: decisions/2026-10-20-test-the-running-app-gray-box

### Example: a window on a Retina display
* Given the window's content is 800 by 600 points on a display with 2 pixels per point
* When an agent asks for a screenshot of the window
* Then it gets an image of 1600 by 1200 pixels
* And asking for the rectangle at 0,0 of 100 by 50 points gives an image of 200 by 100 pixels

## Rule: No inspector call shall change the notebook, its folds, the selection, the scroll position or the window
`req~inspector.never-drives~1`
From: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
Decided in: decisions/2026-10-20-test-the-running-app-gray-box

### Example: every call
* Given a notebook is open with a heading folded, a line selected and the view scrolled
* When an agent makes every call the inspector offers
* Then the text, the folds, the selection, the scroll position and the window's frame are what they were before
