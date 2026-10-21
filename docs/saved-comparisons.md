# Saved comparisons and HTML export (1.2)

Plan for saving a comparison to reopen later, exporting one as HTML to share, and previewing
saved comparisons in Quick Look. Written 2026-10-21.

## Why

Before-and-after captures from a troubleshooting session or a change window are worth keeping:
to look at again later, or as a record that the post-change checks passed. Today a comparison
lasts only as long as its window, and pasted text, the usual case for `show` output, has no
file to reopen.

The main use is reopening a comparison in Juxta, so the saved file comes first. HTML export is
for sharing with people who don't have Juxta.

## Behavior

### Saving

- **File › Save Comparison…** (⌘S) writes both sides to one `.juxta` file. It always shows a
  save panel, because a comparison is a snapshot with no unsaved changes to track. The panel has
  fields for the left name, the right name and a note (a ticket number or purpose). The names
  start as the pane names, so pasted sides can be given a real name instead of "Pasted Text".
- The default file name is `<left> vs <right>.juxta`, or the note when there is one.
- **Each side's original bytes are saved**, so encoding, BOM, line endings and the final newline
  come back exactly as they were. Pasted text is saved as UTF-8.
- File sides are read again from disk when saving and checked against the digest from when they
  were loaded. If a file changed or is gone, an alert says which one and offers Reload or Cancel.
  Juxta never saves bytes it didn't compare.
- The item is disabled until both sides are filled.

### Opening

- A `.juxta` file opens in a new window when you double-click it, pick it with ⌘O, drop it on
  Juxta, choose it from Open Recent, or run `juxta saved.juxta`. A `.juxta` file never fills one
  side of an existing window.
- The window title is the file name, and the pane headers show the saved names. The subtitle
  adds the save date, the note and the options it was saved with, e.g. "Saved Oct 21, 2026 ·
  CHG0012345 · Ignore Timers", along with the usual hidden-difference notes.
- **The saved options apply to that window only.** Toggling an option there changes just that
  window and doesn't change the remembered options other windows use.
- Reload (⌘R) is disabled, since the sides are a snapshot. Swap, navigation, selection and copy
  work as usual. ⌘S saves again with the same names and note filled in.
- If a side's bytes don't match their saved SHA-256, the comparison opens anyway with a notice
  saying the file was edited after it was saved. A file with an unknown version or bad structure
  doesn't open, and an alert says why.

### Exporting HTML

- **File › Export as HTML…** writes one self-contained page with inline CSS and no scripts:
  - A header with the names, the note, the date, the options, change counts and any
    hidden-difference notes.
  - The two sides next to each other, with line numbers, the same red, green and blue rows,
    changed characters highlighted, and hatching where a side has no line.
- The save panel can export **changes with N lines of context** (the default, N = 3, with "⋯ 120
  unchanged lines" separators) or **all lines**.
- The page follows light and dark mode (`prefers-color-scheme`), and printing it works.
- It works from any comparison window, saved or not.

### Quick Look

- Pressing Space on a `.juxta` file in Finder shows the HTML export's changes-only page. For
  very large diffs it is cut off after the first 200 changes, with a line saying how many
  more there are.

### Command line

- `juxta-diff --save out.juxta [--note TEXT] left right` lets a capture script record a
  comparison without opening the app.
- `juxta-diff --html [--context N | --all] left right` writes the HTML to stdout.
- Wherever `juxta-diff` expects two files, it also accepts one `.juxta` file and uses the
  options saved in it, unless an ignore flag is given on the command line.
- `scripts/juxta` accepts a single `.juxta` argument.

## File format

A `.juxta` file is a UTF-8 header followed by the two sides' bytes. You can read it in any text
editor, as long as the sides themselves are text.

```
juxta-comparison 1
saved: 2026-10-21T14:03:12-04:00
note: CHG0012345 post-change verification, core1
options: ignore-timers

left
name: core1 show ip bgp summary (pre)
source: pasted
bytes: 48211
sha256: 9f2c…

right
name: post.txt
source: /Users/chris/captures/post.txt
bytes: 48390
sha256: 41aa…

--- left
<48211 bytes>
--- right
<48390 bytes>
```

- The first line names the format and its version. A higher version doesn't open.
- The header is `key: value` lines. Unknown keys are ignored, so later versions can add fields.
  Values are a single line: newlines in a note or name are saved as spaces.
- `options` lists `ignore-whitespace`, `ignore-case` and `ignore-timers`, separated by spaces.
  It is left empty when no option is set.
- `source` is `pasted` or the path the side was loaded from. It's only for reference: Juxta
  never reads that path again.
- Each body starts on the line after `--- left` or `--- right`, is exactly `bytes` long, and is
  followed by one `\n`. The byte counts make parsing exact for CRLF, UTF-16 and missing final
  newlines.
- UTType `com.moondustries.juxta.comparison`, extension `.juxta`, conforming to `public.data`
  and `public.content`. It doesn't conform to `public.text`, because the sides may be UTF-16,
  but TextEdit or BBEdit can still open the file when asked to.

## Changes

1. **JuxtaCore `SavedComparison.swift`:** a `SavedComparison` struct with the note, date,
   options, and for each side its name, source, bytes and digest. It has `encode() -> Data` and
   `init(data:) throws`, and `documents()` returns a `TextDocument` for each side. File sides
   are rebuilt with `init(fileData:name:url: nil)` so their format and digest come back, and
   pasted sides with `init(text:name:)` so they are still treated as pasted.
2. **JuxtaCore `HTMLReport.swift`:** renders a `DiffResult` and both documents as HTML, with
   inline changes from `Comparator.inlineChanges` computed for each modified row it includes.
   It escapes everything, since banners and descriptions contain `<` and `&`. Context and the
   change limit are parameters. The colors are its own CSS, chosen to match `Theme`.
3. **`CompareWindowController`:**
   - An `options` property that starts from `Preferences.options`. Recompute and the option
     toggles use it, and toggles write `Preferences` only when the window isn't a saved
     comparison.
   - A `saved: SavedComparison?` property for the subtitle and the ⌘S defaults.
   - `saveComparison(_:)` with the panel's accessory view, which re-reads and verifies file
     sides, and `exportHTML(_:)`.
   - `canReload` is false for saved windows.
4. **`AppDelegate.openFiles`:** routes `.juxta` URLs to new windows built from
   `SavedComparison` before handling the remaining files as today. It also notes them in
   `NSDocumentController.shared` so they appear in Open Recent.
5. **`MainMenu.fileMenu()`:** Save Comparison… (⌘S) and Export as HTML… after Reload, and an
   Open Recent submenu.
6. **`Info.plist`:**
   - `UTExportedTypeDeclarations` for the new type.
   - A `CFBundleDocumentTypes` entry for it with role Viewer and rank Owner, placed before the
     existing text/data entry.
7. **`juxta-diff`:** `--save`, `--note`, `--html`, `--context`, `--all`, and accepting a single
   `.juxta` file. **`scripts/juxta`:** a one-argument form.
8. **Quick Look extension:** an Xcode target (`JuxtaQuickLook`, sandboxed, linking JuxtaCore)
   with a `QLPreviewingController` that uses data-based previews (`QLIsDataBasedPreview`) and
   returns `HTMLReport` output as a `QLPreviewReply`. `scripts/build.sh` builds with SwiftPM,
   which can't make an app extension, so only Xcode builds and releases include it. Say so in the
   README.
9. **README:** a **Save and share** item under Using it, and the new `juxta-diff` flags.

Build it in that order: the format and its tests, the app's save and open, then HTML, then Quick
Look. Each step can ship without the steps after it.

## Testing

- **Round trip (unit tests):** for every pair in `Fixtures/pairs`:
  - Encoding then decoding gives the same bytes, digests, `TextFormat` and lines.
  - `hiddenDifferences` and `isByteIdentical` come out the same as from the original files.
  - Also cover a pasted side and a note with a newline in it.
- **Bad files (unit tests):** a truncated body, a byte count past the end, a missing header
  line, version 2, and a digest mismatch, which opens with a flag rather than throwing.
- **HTML (unit tests):** golden output for a small fixture, both with context and with all
  lines. Also check escaping, using a banner with `<`, `>` and `&`, and context merging when
  two changes are closer than 2N lines.
- **`juxta-diff`:** a saved file gives the same `--stats` and exit status as the original pair.
- **By hand:**
  - Save with pasted text on both sides, with files on both sides, and one of each.
  - Change a file on disk before saving to check the alert.
  - Reopen from Finder and from Open Recent.
  - Toggle an option in a saved window, then check that a new window's options didn't change.
  - Open an export in Safari in light and dark mode, and print it.
  - Use Quick Look on a large saved comparison.
- **Optional:** a `saveReopen` step in `JUXTA_ACTIONS` that writes to `$TMPDIR` and replaces
  the window with the reopened one, so the snapshots show the subtitle.

## Not in 1.2

- Three-way comparisons, or comparing a saved file against a new capture.
- Editing the note or names without saving again.
- PDF export. Print the HTML instead.
- Compressing the file. `show` output compresses well, but compression would make the file
  unreadable without Juxta.
