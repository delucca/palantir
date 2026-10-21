# Feature: Notebook window

Shows a Markdown notebook from disk in the palantir window, read-only.

## Rule: When the user chooses a Markdown file in File > Open, palantir shall show its whole text in the palantir window
`req~notebook-window.open~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings
Decided in: decisions/2026-10-17-build-the-notebook-editor-on-textkit-2

### Example: opening a notebook
* Given a file notebook.md on disk
* When the user chooses notebook.md with File > Open
* Then the palantir window shows the text of notebook.md, character for character

## Rule: The notebook view shall let the user select text and shall not let the user change it
`req~notebook-window.read-only~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings

### Example: typing into an open notebook
* Given notebook.md is open
* When the user selects its first line and types "x"
* Then the first line is still selected
* And the text in the view is unchanged
