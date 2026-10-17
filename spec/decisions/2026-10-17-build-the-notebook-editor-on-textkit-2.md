---
status: accepted
date: 2026-10-17
from: one-pagers/2026-10-16-open-notebook-fold-headings
supersedes:
superseded-by:
---
# Build the notebook editor on TextKit 2

## Context

The notebook editor is the part of palantir most likely to fail, and the open-notebook one-pager exists to test it. On macOS 27 the standard AppKit text view lets a subclass skip paragraphs and mark headings during viewport layout, so folding needs no replacement view. MarkEdit's authors, who say they know TextKit 1 and 2, chose CodeMirror 6 in a web view instead, finding folding much harder in TextKit. Two risks are known: hiding paragraphs through `textContentManager(_:shouldEnumerate:options:)` has left blank space the size of the hidden text (an Apple forum report from 2023, still unanswered), and STTextView's author reported in 2025 that TextKit 2 estimates document height unstably, so the scroller jitters, even in TextEdit.

## Decision

The notebook editor is a subclass of AppKit's `NSTextView` on TextKit 2. Folding skips paragraphs through the content storage delegate and marks headings from the viewport layout callbacks. The code never touches `layoutManager`, which drops the view to TextKit 1 for good. This is decided before the spike runs, and the spike tests it.

## Rejected

- CodeMirror 6 in a WKWebView: the strongest folding and editing core, but it adds JavaScript and a bridge to Swift inside the app; it is the fallback if the spike fails.
- STTextView: TextKit 2 underneath with the same layout risks, and on macOS 27 it no longer adds what the standard view lacks.
- A text view of our own without TextKit: rebuilds input methods, selection, undo and accessibility, the months of edge cases the one-pager warns about.

## Consequences

- palantir requires macOS 27 for the viewport layout callbacks.
- Editing, with its input methods, undo grouping and selection across folds, stays untested until a later one-pager makes the view editable.
- Revisit if the spike shows blank space or a jumping scroller that the viewport callbacks cannot fix, or if the user finds folding worse than Org; CodeMirror 6 in a web view then replaces it.
