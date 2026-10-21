---
status: accepted
date: 2026-10-20
from: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
supersedes:
superseded-by:
---
# Render the inspector's screenshots inside palantir, without ScreenCaptureKit or a certificate

## Context

The one-pager asks whether palantir needs its own ScreenCaptureKit capture, and so a self-signed certificate. ScreenCaptureKit needs the Screen Recording grant for the process that captures, and `just bundle` signs palantir ad hoc, so a grant tied to palantir's identity is lost on every rebuild and only a stable certificate would keep it. The inspector's screenshots must be full resolution, whole or cropped to a rectangle in window points, and must work while palantir sits covered and inactive behind the person's work.

Runs on 2026-10-20 settled it. `cacheDisplay(in:to:)` renders the content view at the window's backing scale, 1920 by 1200 pixels for 960 by 600 points, and differs from `screencapture -l` of the same window in front in 0.1% of its pixels, at the window's edges and corners. Covered and inactive, the rendering is identical to the one in front, while `screencapture -l` and a ScreenCaptureKit window capture both fail on the covered window. `cacheDisplay` leaves out the scrollers, which AppKit draws in layers of their own, and a `CAMetalLayer` renders transparent.

## Decision

- The inspector's `screenshot` waits for settled layout, renders the window's content view in-process at the display's resolution, whole or cropped to a rectangle in window points from the content's top-left corner, draws every shown scroller over it, and answers with a PNG.
- palantir has no ScreenCaptureKit capture of its own, asks for no Screen Recording grant and needs no certificate.
- The real window, title bar and all, comes from `palantir-drive capture`, with palantir in front for it.
- Once the terminal draws with Metal, its state comes from its buffer, as decisions/2026-10-20-test-the-running-app-gray-box says, and its pixels from `palantir-drive capture`, until a later decision gives the inspector a rendering of the terminal's drawable.

## Rejected

- ScreenCaptureKit inside palantir with a self-signed certificate: it would capture Metal content, which nothing draws yet, at the price of a certificate and a grant on every machine, and it fails on a covered window.
- The driver's capture alone: it needs palantir in front, so every screenshot would take the person's focus, and its crop is in screen pixels, not the window points the state reports.
- `CALayer.render(in:)`: in a test window it drew nothing where `cacheDisplay` drew the text.

## Consequences

- Screenshots show the content view as AppKit draws it, with its scrollers drawn on top: no title bar, shadow, overlapping windows or Metal layers. An overlay scroller whose knob AppKit has faded without changing its alpha can still show in a screenshot.
- A screenshot waits for settled layout and fails like `wait` when layout never settles.
- The terminal's one-pager states how agents read its pixels.
- Revisit when the terminal arrives, or if agents need the composited window without taking focus.
