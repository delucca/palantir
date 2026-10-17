# Feature: Heading outline

Finds each heading in a Markdown notebook and the text it owns, without a window.

## Rule: Each heading shall own the lines after it, up to the next heading of the same or a higher level or the end of the file
`req~heading-outline.owned-range~1`
Needs: utest
From: one-pagers/2026-10-16-open-notebook-fold-headings
Decided in: decisions/2026-10-17-parse-markdown-with-swift-markdown

### Example: nested headings
* Given a notebook with these lines
  | line | text              |
  | ---- | ----------------- |
  | 1    | # Tasks           |
  | 2    | ## Fix the reaper |
  | 3    | It leaks.         |
  | 4    | ## Ship bilbo     |
  | 5    | # Notes           |
  | 6    | Done.             |
* When palantir reads its outline
* Then the headings own these lines
  | heading           | owned lines |
  | ----------------- | ----------- |
  | # Tasks           | 2 to 4      |
  | ## Fix the reaper | 3           |
  | ## Ship bilbo     | none        |
  | # Notes           | 6           |

## Rule: A line starting with "#" inside a fenced code block shall not count as a heading
`req~heading-outline.fenced-code~1`
Needs: utest
From: one-pagers/2026-10-16-open-notebook-fold-headings
Decided in: decisions/2026-10-17-parse-markdown-with-swift-markdown

### Example: a shell comment in a code block
* Given a notebook whose line 1 is "# Setup", whose lines 2 to 4 are a fenced code block holding the line "# install deps", and whose line 5 is "## Run"
* When palantir reads its outline
* Then its only headings are on lines 1 and 5
* And "# Setup" owns lines 2 to 5
