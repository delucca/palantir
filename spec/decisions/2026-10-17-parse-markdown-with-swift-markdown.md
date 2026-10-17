---
status: accepted
date: 2026-10-17
from: one-pagers/2026-10-16-open-notebook-fold-headings
supersedes:
superseded-by:
---
# Parse Markdown with swift-markdown

## Context

Folding needs each heading and the range it owns, and every later editor feature, such as TODO cycling, structural moves and links, reads the same structure. Headings in CommonMark depend on context: a `#` line inside a fenced code block is code, `#tag` with no space is text, a line underlined with `===` is a heading, and up to three spaces of indent are allowed. Across 515 bilbo notes, 29 hold 119 `#` lines inside code fences, mostly shell comments, that a line scan would take for headings.

## Decision

palantir parses Markdown with swift-markdown (`swiftlang/swift-markdown`, built on cmark-gfm) in a library target, and palantir's own code there turns the parse into what the editor needs, such as the range each heading owns. A node's `range` gives a line and a column counted in UTF-8 bytes, so the library maps it to the UTF-16 offsets the text view uses. The package is pinned to an exact release, 0.9.0 today, and `Package.resolved` is committed.

## Rejected

- A hand-written parser: it has to re-implement CommonMark's block rules, and fenced code alone breaks a line scan.
- tree-sitter-markdown through SwiftTreeSitter: it parses incrementally, but its own README says "it is not recommended to use this parser where correctness is important".

## Consequences

- swift-markdown parses the whole file on every call and has no incremental mode. Notebooks are small, but the cost of a parse per keystroke stays unmeasured until the view is editable.
- swift-markdown's parse options are a fixed set with no way to add syntax, so palantir's task syntax, such as TODO keywords and session pins, reads CommonMark blocks and adds its meaning on top.
- Revisit if mellon ships a Markdown parser shared with bilbo, or if a full parse per keystroke proves too slow.
