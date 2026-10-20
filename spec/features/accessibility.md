# Feature: Accessibility

What palantir exposes in the accessibility tree, which assistive tools and the agents' driver both read.

## Rule: Every view palantir draws itself shall have an accessibility label
`req~accessibility.custom-view-labels~1`
Needs: utest
From: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
Decided in: decisions/2026-10-20-test-the-running-app-gray-box

### Example: the folded marker
* Given a notebook with "## Fix the reaper" folded is open
* When the window's accessibility tree is read
* Then the folded marker of "## Fix the reaper" has the label "Folded"
