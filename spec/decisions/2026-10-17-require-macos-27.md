---
status: accepted
date: 2026-10-17
from: one-pagers/2026-10-16-open-notebook-fold-headings
supersedes:
superseded-by:
---
# Require macOS 27

## Context

palantir is a personal tool, and the Mac it runs on, rivendell, has macOS 27.0.1, Xcode 27.1 and Swift 6.4. `Package.swift` sets the minimum to macOS 26 and `Info.plist` sets `LSMinimumSystemVersion` to 26.0. From the 2027 releases on, `NSTextView` conforms to `NSTextViewportLayoutControllerDelegate`, so a subclass can adjust and draw each paragraph during viewport layout, which is how Apple's WWDC26 session 370 builds collapsible sections. Before that, the text view does not open those callbacks to a subclass, and drawing per paragraph, such as a fold marker, means replacing the view.

## Decision

palantir requires macOS 27. `Package.swift` declares `.macOS(.v27)`, `Info.plist` sets `LSMinimumSystemVersion` to 27.0, and code calls macOS 27 APIs without availability checks.

## Rejected

- Stay on macOS 26: folding would need STTextView or a text view of our own, rebuilding the input, selection, undo and accessibility that the standard view gives for free.
- Support macOS 26 and 27 behind availability checks: two folding paths for a tool that runs on one Mac.

## Consequences

- `.v27` needs `swift-tools-version: 6.4`, up from 6.2, so building needs Xcode 27 or a Swift 6.4 toolchain.
- palantir does not launch on a Mac still on macOS 26.
- Revisit if palantir must run on a Mac that cannot update to macOS 27.
