# Testing plan

How we check that Juxta is correct, readable and fast, and how it compares with the best
tools. Written 2026-09-30. Update the status column as work lands.

## Scope

Juxta is a read-only, side-by-side viewer for router configs and `show` output. These parts
of a general diff-tool audit don't apply, and we're skipping them on purpose:

- **Patch export and `git apply` round-trips.** Juxta doesn't write patches. The equivalent
  check is that the rows rebuild both inputs exactly (`testRowsReconstructBothSides`). Revisit
  if we add unified-diff export (open question below).
- **3-way merge suites** (diff3, ConflictBench). No merge.
- **Code-structure diff benchmarks** (GumTree, difftastic). A different kind of product.
- **Porting git's `t40xx` shell tests.** Differential testing against `git diff` (step 2) gets
  the same value with less work.
- **Golden-screenshot UI tests.** Brittle. Screenshots are for reference, not assertions.

Already covered by `Tests/JuxtaCoreTests`:
- Myers is optimal, checked against brute-force LCS on random inputs.
- Patience produces valid alignments.
- Rows rebuild both sides; "identical" holds exactly when the line arrays are equal.
- Similar-line pairing, the ignore options (whitespace, case, timers), and timer detection
  including false matches (`TimersTests`), basic line splitting.
- A 200k-line routing table compares in under 3s.

## Suspected problems (from reading the code; confirm with the fixtures)

| # | Problem | Where | Fixtures |
|---|---|---|---|
| 1 | ✅ Fixed. CRLF vs LF, BOM vs none, and a missing final newline all showed as **identical** | `TextDocument` strips CR, BOM and the final newline | 01, 03, 04, 05 |
| 2 | ✅ Fixed. UTF-16 rejected as binary (NUL check runs before any encoding detection) | `TextDocument.load` | 06, 07 |
| 3 | ✅ Fixed. CR-only (classic Mac) files load as one line | splits on LF only | 02 |
| 4 | ✅ Fixed. Invalid UTF-8 turned the whole file into CP1252; now per line, tested | `TextDocument.init` | 08, 09 |
| 5 | Hunks may slide one line off around repeated `!`, braces or blank lines (no slider/indent heuristic) | `SequenceDiff` | 30, 31, 41, 44, 49 |
| 6 | Word highlights are per character (`10.0.0.1`→`10.0.0.12` highlights only `2`) | `Comparator.inlineChanges` | 37, 39, 40 |
| 7 | Word highlights computed during drawing, 50ms budget per line; may stutter | `DiffPresentation.inlineChanges` | 20, 66 |
| 8 | ✅ Fixed. Unrelated files hit the 5s timeout; huge changed blocks were paired positionally and drifted. Regions with no common line now skip the search, and big regions pair by unique first-two-word keys plus a banded alignment. Pairing shares the time limit and has a size limit; past either, the region is left unpaired and the result is marked approximate. Few unique lines (64) compare in ~0.05s | `SequenceDiff`, `Comparator.appendHunk` | 62–66 |

## Step 1: Truthfulness

The worst thing a diff tool can do is say "identical" when the files differ.

- [x] Loader tests driven by `Fixtures/pairs` (`Tests/JuxtaCoreTests/FixtureTests.swift`),
      including a check over every pair that different bytes are never reported as identical.
- [x] `TextDocument.format` records encoding, BOM, line endings and final newline, plus a
      SHA-256 of the file's bytes.
- [x] Differences in those show in each pane header (the differing parts in orange) and in the
      window subtitle ("Same text · differs in line endings"), not as changed lines. Text that
      matches when bytes don't, for any other reason, says so too. Pasted text has no format.
- [x] UTF-16 detected by BOM, or by an alternating NUL pattern without one, before the binary check.
- [x] Split on CR-only line endings.
- [x] Invalid UTF-8 only affects its own lines (read as Windows Latin 1), not the whole file.
- [x] Lines are compared by exact bytes: NFC and NFD forms of the same text used to match.
- [x] The binary-file alert says which side failed.
- [x] Random rebuild-both-sides test covers the ignore options, and Ignore Timers; the timeout
      path was already covered (`testTimeoutIsReportedAndStillValid`).

## Step 2: Compare against git

- [x] Add a `juxta-diff` command-line target (SwiftPM executable using `JuxtaCore`) that
      prints hunks and changed/deleted/inserted counts for two files (`--stats`, `--rows`,
      `--json`; exits 0/1/2 like `diff`).
- [x] A script that runs every pair through Juxta and through `git diff --no-index` with
      `--diff-algorithm=myers|patience|histogram` (`scripts/compare-git.py`; file pairs,
      fixture folders, or `--repo PATH --commits N --paths …` to walk a repo's history). It
      flags pairs where Juxta's changed lines exceed histogram's by more than 20% (and 5
      lines), and lists pairs with the same lines changed but different hunk boundaries.
- [ ] Corpus, configs first:
  - [ ] real config backup history in `Fixtures/private/` (RANCID/Oxidized if available)
  - [x] public config fixtures (NAPALM test data, Batfish example networks)
  - [ ] `show` output captured twice (NAPALM's mocked `show` outputs stand in for now)
  - [x] a few hundred consecutive commits from a code repo as a general check
- Git is a comparison point, not an oracle: a difference becomes a fixture, then we decide
  which result is better.

**Results (2026-10-01).** 1,918 modified-file pairs: Batfish test configs and example
networks (last 2,500 commits touching them, 1,085 pairs, IOS/XR/NX-OS/EOS/Junos/FortiOS/F5/
PAN-OS), NAPALM mocked `show` output and configs (118 pairs), and git.git `*.c`/`*.h` (last
300 commits, 715 pairs); plus `Fixtures/pairs`. Juxta's comparable count is deleted +
inserted + 2 × modified, so pairing lines as modified costs nothing against git's delete +
insert. The script adds a missing final newline before running git (which would count the
last line as changed) and skips pairs whose line endings, encoding or BOM differ (one NAPALM
LF → CRLF pair), leaving 1,917.

| | Lines changed | Hunks |
|---|---|---|
| Juxta | 31,250 | 5,193 |
| git myers | 30,736 | 5,412 |
| git patience | 31,374 | 5,187 |
| git histogram | 31,416 | 5,163 |

- **No pair flagged.** Juxta never changed more lines than histogram (or patience): equal in
  1,881 pairs, fewer in 36 (median and p95 ratio 1.00), where the Myers check found a smaller
  diff (up to 44 lines fewer, on NAPALM `show ip interface`).
- **More lines than Myers in 2 pairs** (NAPALM `nxos/initial.conf`, `new_good.conf`; 1,747 vs
  1,463). Not worse: Myers keeps blank lines and `!#logging event …` lines across unrelated
  interface stanzas (153 hunks); Juxta anchors on the unique `interface EthernetX/Y` lines (38).
- **Same lines, different hunk boundaries in 35 pairs** (23 config, 11 C, 1 `show`; 39
  before the slider fix below):
  - Juxta better or equal in most config cases: it ends an inserted block on its own
    `!`/`#` closer where git starts it with the previous block's (Arista BGP, NX-OS, Junos,
    IOS vrf).
  - Equal-cost alternatives (the 11 C files, NAPALM `show bgp neighbors`): which repeated
    blank line, `}` or duplicated block is kept differs; both read fine, and Juxta pairs the
    edited lines as modified.
  - ✅ Fixed: 5 config pairs in 3 patterns where Juxta was worse (fixtures 51–53). A
    blank-separated block appended after a block with the same closer started on the
    previous block's `!` (IOS XR vrf) or `}` (F5 ltm rule), and a FortiOS `edit … next`
    entry started on the previous entry's `next` and ended on its nested `end`. The slider's
    "whole block" rule now lets leading blank lines open a group (checking the first non-blank
    line instead), requires the closer to be no deeper than that line, and counts
    `next` as a separator. Rerun: only 6 of 1,917 pairs changed (lines and hunk counts
    unchanged): the 5 now match git, and 1 (`ios-vrf-leaking`) now differs from git for the
    better (the new vrf ends on its own `!` instead of starting on the previous one's).
- Juxta compare time: p50 0.08 ms, p95 0.73 ms, max 2.4 ms (largest file 7,882 lines); none
  approximate.
- Git places changes differently with `-U0` than with context, so the script reads hunk
  boundaries from a normal diff.
- To rerun: `swift build -c release`, clone the repos outside this one, then e.g.
  `scripts/compare-git.py --repo batfish --commits 2500 --paths ':(glob)**/testconfigs/**'
  ':(glob)networks/**' --per-commit 5 --keep /tmp/pairs` (`--keep` saves the pairs to inspect
  with `juxta-diff --rows`).

## Step 3: Config alignment fixtures

`Fixtures/pairs/30-50` are hand-written config cases, each with "Look for" in `about.txt`.

- [x] Turn each into a Swift test that asserts the expected row layout (row kinds and which
      lines pair up), so they become regression tests (`AlignmentTests`, plus 65).
- [x] Fix what fails (all `AlignmentTests` pass, including 51–53 from step 2):
  - ✅ a slider heuristic like git's indent heuristic, preferring hunks that end on `!`, `}`
    or a blank line and start at a less-indented line (`Slider`, fixture 35)
  - ✅ blocks swapping places keep the most lines (fixture 45): small regions are also
    solved by plain Myers, which wins when patience's anchors keep fewer lines
  - ✅ token-boundary word highlights, the rule `AlignmentTests` encodes: split lines into
    tokens on whitespace and `. / : , - [ ] ( )`, and highlight whole tokens only. When both
    lines have the same number of tokens and identical separators (fixed-shape `show`
    output), compare tokens by position; otherwise match tokens by content (token-level
    LCS). We split on `.` on purpose, so a single changed octet
    highlights alone (`10.0.12.[1]`)
- [x] Presentation and alignment improvements:
  - ✅ show invisible characters on changed lines only (line-ending glyphs, tabs, trailing
    spaces, NBSP, a badge for zero-width or control characters such as NUL)
  - ✅ pair ACL/prefix-list entries by content despite resequencing (fixture 32; the
    same-first-word rule skips a leading sequence number)
  - ✅ keep similar lines paired inside big changed blocks (fixture 65), and never pair
    dissimilar lines (45, 47, 48)
  - ✅ jump to the first highlight within a very long line (fixture 20); next/previous also
    step through far-apart highlights in one row
- [ ] ~~Add 10–15 pairs from real config history~~ Skipped for now (decided 2026-10-01) (`Fixtures/private/`), each with an
      `about.txt`. These are the panel that matters; a blind panel against other tools isn't
      worth the effort.

## Step 4: Performance

Targets, measured on an Apple Silicon Mac and enforced in `PerformanceTests`:

- `swift test` runs the quick checks only (2k, 60, 61, 64, 65, synthetic 200k), with limits
  about 10× the measured debug time so a busy machine doesn't fail them.
- `JUXTA_PERF=1 swift test` adds the multi-second fixtures (62, 63, 66, 67) and tightens
  debug limits to about 3× the measured debug time.
- `swift test -c release -Xswiftc -enable-testing` runs everything against the release
  targets.

Fixtures 60–66 need `scripts/make-fixtures.py`, 67 `--huge`; missing ones are skipped. Measured 2026-10-01 on an Apple M4 Pro: load + compare, from
`PerformanceTests` in each configuration (debug runs 8–20× slower).

| Input | Fixture | Target | Measured (release) | Measured (debug) |
|---|---|---|---|---|
| 2k lines, 5% changed | (in test) | < 50 ms compare | 1 ms | 15 ms |
| 20k lines, 5% changed | 60 | < 250 ms | 16 ms | 0.17 s |
| 200k lines, 1% changed | 61 | < 1 s | 0.15 s (load 43 ms) | 1.3 s |
| 20k / 100k unrelated lines | 62, 63 | finishes inside the time limit; result still correct | 0.15 s / 0.73 s | 2.4 s / 5.1 s (63 hits the 5 s limit) |
| 100k lines, 20-line vocabulary | 64 | same | 56 ms | 0.57 s |
| 1000-line changed block with inserts | 65 | same; old and new lines stay paired (no drift) | 14 ms | 0.15 s |
| 50k lines, every line changed | 66 | smooth scrolling with inline highlights | 0.15 s; 2.6 ms per screen | 2.9 s |
| 1M lines (~78 MB per side) | 67 (`--huge`) | opens; note peak memory | 0.91 s; 563 MB peak (`juxta-diff`), 700 MB (app) | 6.2 s |

- [x] First-paint time and scroll-through timing: `JUXTA_SCROLLBENCH=<screens> Juxta left
      right` (release builds too) logs the time from process start to the first compared
      paint, then pages down and times word highlights and `DiffPaneView.draw` for each
      screen (both panes, 1280×820 window). Release: first paint 61 ≈ 280 ms, 64 ≈ 190 ms,
      66 ≈ 290 ms, 67 ≈ 1.05 s (about 130 ms of each is app launch). Paging through all of
      66: 2.6 ms avg / 5.6 ms max per screen; 61: 1.4 / 4.7 ms.
- [x] Progress indicator and Cancel for compares that run longer than about 0.5s (the
      no-match time limit is 5s). After 0.5 s a floating bar (spinner, "Loading…"/"Comparing…",
      Cancel / ⎋) appears over the panes; cancel stops the engine (`Cancellation`, checked with
      the deadline) within ~10 ms and shows the files unaligned until ⌘R.
- [x] Profile word-highlight cost while scrolling fixture 66. The highlights themselves cost
      0.1 ms per screen; the stutter was `CTLineGetOffsetForStringIndex` placing them
      (grapheme analysis per line: 8.2 ms avg / 10.8 ms max per screen). Printable-ASCII
      lines now use column × character width, which is exact in the monospaced font.
- Peak memory at 1M lines is mostly the `[String]` lines (about 140 bytes each with heap
  storage, ×2M lines); the rows are 12 bytes each. Acceptable, so left as is.

## Step 5: App behavior checklist

Automated where possible on 2026-10-01 with the debug snapshot hook (`JUXTA_SNAPSHOT`, plus
`JUXTA_ACTIONS=next,prev,swap,reload` and `JUXTA_AX=1`, which prints the rows, change map
and announcements VoiceOver gets).

- [x] `git difftool -t juxta` (with `-c`) on modified, added and deleted files. Checked with a
      temporary repo and a stand-in for `open`: git passes `/dev/null` for the missing side
      (staged and commit-to-commit alike). `scripts/juxta` used to copy it as an empty file
      named `null` (and without `-c` would hand `/dev/null` to `open`); now that side is an
      empty placeholder named `<file> (absent)` in either mode, which the pane shows as
      "Empty file". Other missing paths still fail with exit 66.
- [x] ⌘R reload after a file changes on disk; ⌥⌘S swap. Driven through the controller:
      editing a file between snapshots and reloading picks up the change (fixture 37: 6 → 7
      changes). Swap mirrors highlights and kinds and moves the format labels with their
      files (fixtures 06, 37). Paste flows were covered by the recent load/paste work.
- [x] Non-UTF-8 and UTF-16 files display correctly (06–09): text identical across encodings,
      headers read UTF-16 LE/BE, Windows Latin 1, "UTF-8 with invalid bytes" (in orange
      where they differ), and only 09's bad line shows as modified (`Müÿller`, bytes FC FF).
- [x] VoiceOver: each pane is a list labeled "Left: name" whose visible rows are static
      text, e.g. "Line 30, modified: ip address 10.0.12.5 …. Changed: 5"; filler rows read
      "No line, added on the right"; unchanged rows give no kind. The change map is a slider
      ("6 changes, at change 1, showing rows 15 to 58 of 113") whose increment/decrement go to
      the next/previous change. Navigating announces "Change 1 of 6, 1 line modified, at
      line 30". The header's file icons are hidden from VoiceOver.
- [x] Add/delete/change colors meet contrast in light and Dark Mode. Computed from `Theme`
      under both appearances (WCAG ratio). Text on every row background is ≥ 6.2:1 (worst:
      selected rows in dark, then highlight in dark at 6.5). Fixed: line numbers (tertiary
      label, 1.6–2.3:1 → own gray, ≥ 4.7:1; label color on selected rows), badge labels
      (secondary label, 2.7–4.1:1 → text color, ≥ 5.2:1) and the orange "differs" header text
      in light mode (2.3:1 → darker orange, 5.6:1). Highlight vs modified row: 1.4:1 / ΔL\* 12
      light, 2.0:1 / ΔL\* 19 dark. Left as is: invisible-character marks (tertiary label,
      ~2:1, faint on purpose) and the header's secondary-label path line (3.95:1 light; a
      system color that Increase Contrast strengthens).
- [x] Increase Contrast and color-independent kinds. `Theme` colors have high-contrast
      values (via `bestMatch`; `JUXTA_HC=1` forces them in snapshots): rows stand further
      from unchanged ones (1.3–1.95:1 vs 1.1–1.55:1), text and line numbers are ≥ 7:1 on
      every row, and changed-character highlights get a 1.5 pt outline (≥ 6:1 against the
      row). The gutter marks each line +, − or ~ so the kind doesn't rest on color.
- [x] Identical files and empty files show a clear message (12–14). Byte-identical files say
      "Files are identical" ("Both files are empty" for 12) in the subtitle and in a note at
      the bottom of the window (hidden while the last rows would be under it); same text with
      other differences keeps its subtitle in the note, with an info icon instead of a
      checkmark. An empty file's pane says "Empty file".

Manual before release (needs a person or the installed app):

- [ ] `git difftool -t juxta` with the installed app: both files open in one window, in
      order, including an added and a deleted file.
- [ ] A real VoiceOver pass: rows read as above when moving through a pane, announcements
      are spoken on ⌥⌘↓/⌥⌘↑, the change map slider steps between changes.
- [ ] ⌘R after editing a file in another app; paste (⌘V, ⌥⌘V, ⇧⌥⌘V) from real `show` output.
- [ ] A glance in Dark Mode and with Increase Contrast on.

## Open questions

- **Unified diff export** (for pasting into tickets and change requests)? If yes, add a
  `git apply --check` round-trip to step 2.
- **Ignore lines matching a pattern** (timestamps, "Last configuration change", counters)?
  Fixtures 38–40 will show whether it's needed. Ignore Timers (#2) now covers ages and uptimes
  (fixtures 22, 23, 39, 40); ignoring lines by pattern, such as fixture 38's header, is still open.
