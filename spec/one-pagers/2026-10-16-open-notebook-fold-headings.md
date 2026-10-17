---
status: draft
date: 2026-10-16
---
# Open a notebook and fold its headings

## Problem

palantir is meant to replace dmacs, where about half the code serves notebook work, and the notebook editor is the part most likely to fail.

Native text editing on macOS is months of edge cases, TextKit 2 is thin on docs, and nobody knows yet whether an editor in palantir can feel as good as Org.

Building the terminal or the switcher first would repeat the June workbench app: the easy plumbing done, the deciding question left open, 26 commits reverted.

## Solution sketch

The smallest slice that tests the editor: open one Markdown notebook and fold its headings. File > Open brings up the standard panel, and the chosen file shows in the palantir window in an AppKit text view on TextKit 2. The view is selectable but not editable.

Folding follows the collapsible sections of Apple's WWDC26 session 370. A subclass of the standard text view skips layout for the paragraphs a folded heading owns, through `textContentManager(_:shouldEnumerate:options:)`, and marks each folded heading from the viewport layout callbacks the text view opens on macOS 27. Selection, undo and accessibility stay with the standard view. The known risk is blank space left where hidden text was: an Apple forum report from 2023 describes it with no answer, and Apple's demo uses the UIKit text view, not AppKit's.

swift-markdown parses the file in a new library target, and code there turns the parse into each heading and the range it owns, up to the next heading of the same or a higher level, so tests cover it without a window. A `#` line inside a fenced code block is code, not a heading. Fold Heading, Unfold Heading, Fold All and Unfold All are menu commands with shortcuts. Fold state lives only in the view, and the file is never written.

## Done when

- File > Open shows a Markdown notebook from disk in the palantir window.
- Folding a heading hides everything it owns and marks it as folded; unfolding shows the same text again.
- A folded heading leaves no blank space where its text was, and the scroller does not jump when it folds or unfolds.
- Fold All leaves only the top-level headings visible; Unfold All shows the whole file.
- A `#` line inside a fenced code block never folds as a heading.
- After any number of folds the file on disk is byte for byte unchanged.
- The user has folded a real notebook in palantir and said whether folding feels as good as Org. The view is not editable, so a yes clears folding, not editing.

## Open questions

- Which notebook is the test file: a live notebook moved to Markdown, or a converted copy? dmacs still reads Org, so moving a live one drops its session pins there.
- Should Tab and Shift-Tab fold, as in Org? Deferred to the modal-keys one-pager.
