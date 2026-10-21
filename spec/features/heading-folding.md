# Feature: Heading folding

Hides and shows the text a heading owns in the notebook view, without touching the file.

## Rule: Fold Heading shall hide the text owned by the innermost heading at the selection and mark that heading as folded
`req~heading-folding.fold~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings
Decided in: decisions/2026-10-17-build-the-notebook-editor-on-textkit-2
Decided in: decisions/2026-10-17-require-macos-27

### Example: folding a task
* Given a notebook with the lines "# Tasks", "## Fix the reaper", "It leaks." and "# Notes" is open
* And the selection is in "## Fix the reaper"
* When the user chooses View > Fold Heading
* Then "It leaks." is hidden
* And "## Fix the reaper" shows the folded marker
* And "# Tasks" and "# Notes" are visible

## Rule: Unfold Heading shall show again exactly the text the heading's fold hid and clear its folded marker
`req~heading-folding.unfold~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings

### Example: unfolding a task
* Given "## Fix the reaper" is folded and the selection is in it
* When the user chooses View > Unfold Heading
* Then the view shows the same text as before the fold
* And "## Fix the reaper" shows no folded marker

## Rule: A folded heading shall leave no blank space where its text was, and folding or unfolding shall not move the heading on screen
`req~heading-folding.no-gap~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings
Decided in: decisions/2026-10-17-build-the-notebook-editor-on-textkit-2

### Example: folding in a long notebook
* Given a notebook taller than the window is open, scrolled so that "## Fix the reaper" is the top line
* When the user folds "## Fix the reaper"
* Then the next visible line starts right below "## Fix the reaper"
* And "## Fix the reaper" is still the top line

## Rule: Fold All shall fold every heading that no other heading owns, leaving only those headings and any text before the first heading visible
`req~heading-folding.fold-all~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings

### Example: folding a whole notebook
* Given a notebook with the lines "Intro.", "# Tasks", "## Fix the reaper", "It leaks.", "# Notes" and "Done." is open
* When the user chooses View > Fold All
* Then only "Intro.", "# Tasks" and "# Notes" are visible

## Rule: Unfold All shall unfold every heading, showing the whole file
`req~heading-folding.unfold-all~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings

### Example: unfolding a whole notebook
* Given a notebook is open with every heading folded
* When the user chooses View > Unfold All
* Then the view shows the whole text of the file

## Rule: Fold Heading and Unfold Heading shall be disabled when no heading is at the selection
`req~heading-folding.disabled-without-heading~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings

### Example: the selection before the first heading
* Given a notebook with the lines "Intro." and "# Tasks" is open
* And the selection is in "Intro."
* When the user opens the View menu
* Then Fold Heading and Unfold Heading are disabled

## Rule: Folding and unfolding shall never write the notebook file
`req~heading-folding.file-untouched~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings

### Example: many folds
* Given notebook.md is open
* When the user folds and unfolds headings any number of times
* Then notebook.md on disk is byte for byte what it was before
