# Selecting part of a line (1.2)

Plan for selecting and copying characters, not just whole rows. Written 2026-10-17.

## Why

Selection is whole rows today: click, shift-click or drag selects rows, double-click selects a
change, ⌘C copies those lines. To copy one address, prefix or interface name you have to copy
the line and trim it somewhere else. A pane should select text the way a text view does.

## Behavior

Text-view conventions in the text area, rows in the line-number gutter:

| Gesture | In the text | In the line-number gutter |
|---|---|---|
| Click | Clear the selection (there's no caret) | Select the row |
| Drag | Select characters, across rows if needed | Select rows (today's behavior) |
| Shift-click | Extend to that character | Extend by rows |
| Double-click | Select a word | Select the change |
| Triple-click | Select the line | — |
| ⌘A | Select all (unchanged) | — |

- **Words fit configs.** A word is a run of letters, digits and `. : / - _`, so one double-click
  takes `10.1.1.1/24`, `2001:db8::1`, `GigabitEthernet0/0/1` or `route-map`. Other characters,
  including spaces, are a word of one character, as in Terminal.
- **One side at a time.** Each pane keeps its own selection, as now. A drag can't cross panes.
- **Hatched rows are skipped.** A selection that spans filler rows copies only real lines.
- **Copy copies the file's text**, not what's drawn. Invisible marks and badges are never
  copied: a tab copies as a tab, and a zero-width space copies as itself.
- **Selection survives recompute.** Toggling Ignore Whitespace and the other options keeps the
  selection on the same lines and columns, as `lineSelection()`/`restore(_:)` does for rows.
- Selected text draws over the change highlights, using the selection colors already in use
  (dimmed when the pane isn't focused).

**Decision for you:** double-click selecting a whole change moves to the gutter. That breaks
what 1.0/1.1 users already know, but double-click for a word is what everyone expects in text.
The other option is to keep double-click for the change and use ⌥-double-click for a word,
which nobody would discover.

## Design

- **Model.** Replace `selection: Range<Int>` (rows) with an anchor and a head, each a
  `(row, offset)`, where the offset is UTF-16 within the line, matching the inline-change
  ranges. A whole-row selection is just offset 0 to the end of the line, so copy and drawing
  handle a single case.
- **Hit testing.** Point → row (as now) → offset. On plain ASCII lines this is arithmetic,
  `(x - textInset) / charWidth`, rounded to the nearer edge, which also covers sliced lines over
  1,000 columns. For other lines, use `CTLineGetStringIndexForPosition` on the invisibles
  display string, then map back to a source offset. That needs the inverse of
  `Invisibles.Layout.displayOffset(_:)`. A point inside a badge snaps to the nearer edge.
- **Drawing.** Each row fills its selected column span using the existing `offset(_:)` helper
  (it already handles invisibles), rather than the whole `rowRect`. A fully selected row still
  fills to the right edge, so multi-row selections read as a block.
- **Gutter.** `LineNumberView` forwards mouse events to the pane today. It needs to call a
  row-selection entry point instead, so the pane can tell a gutter drag from a text drag.
- **Cursor.** I-beam over the text area, arrow over the gutter.
- **Accessibility.** Rows report selected when any part of them is selected. Add
  `accessibilitySelectedText` on the pane so VoiceOver can read a partial selection.

## Testing

The logic that can be wrong goes in JuxtaCore, so `swift test` covers it, the same way
`HorizontalReveal` does:

- Word boundaries: addresses, IPv6, interfaces, punctuation, line edges.
- Mapping display offsets back to source offsets: tabs, badges, wide and combining characters.
- Assembling the copied text: partial first and last lines, filler rows, an empty line in the
  middle, a selection that ends at column 0.

By hand, use the fixtures with tabs, CRLF and non-ASCII text: drag across hatched rows, copy a
word from a 150k-line file, select on a long sliced line and scroll sideways, and toggle each
option with a selection active. Optionally, add a `select` step to `JUXTA_ACTIONS` so snapshots
show how the selection draws in light, dark and Increase Contrast.

## Not in 1.2

- Keyboard selection (shift-arrows, ⌥-shift-arrows). There's no caret navigation today.
- Column (⌥-drag) selection.
- Selecting in both panes at once, or copying both sides as a unified diff.
