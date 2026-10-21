# Feature: Main menu

The menu bar palantir shows, in the order the macOS Human Interface Guidelines give.

## Rule: The menu bar shall list the app menu, then File, Edit, View, Window and Help, in that order
`req~main-menu.hig-order~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings

### Example: a fresh launch
* When palantir launches
* Then the menus after the app menu are File, Edit, View, Window and Help

## Rule: The View menu shall hold Fold Heading, Unfold Heading, Fold All and Unfold All, with no key equivalents
`req~main-menu.view-fold-commands~1`
From: one-pagers/2026-10-16-open-notebook-fold-headings

### Example: the View menu
* When palantir launches
* Then the View menu holds Fold Heading, Unfold Heading, Fold All and Unfold All
* And none of them has a key equivalent

## Rule: Every menu bar item shall show in the accessibility tree with its title and a press action
`req~main-menu.drivable~1`
From: one-pagers/2026-10-20-agents-drive-and-inspect-the-app
Decided in: decisions/2026-10-20-test-the-running-app-gray-box

### Example: a fresh launch
* When palantir launches
* Then every menu bar item except separators shows in the accessibility tree with its title and a press action
