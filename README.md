# Juxta

A small, native macOS side-by-side text diff. Built for comparing router configs and
`show` output: fast on large files, no dependencies.

## Download

Get `Juxta-<version>.zip` from [Releases](https://github.com/ckarwoski/Juxta/releases), unzip it
and move `Juxta.app` to Applications. It's signed and notarized, and needs macOS 14 or later.

To use `juxta` from Terminal (and as a git difftool, below), install the command:

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/ckarwoski/Juxta/main/scripts/juxta -o ~/.local/bin/juxta
chmod +x ~/.local/bin/juxta
```

`~/.local/bin` needs to be on your `PATH`.

## Build & install

```sh
./scripts/build.sh            # builds build/Juxta.app
./scripts/build.sh --install  # also copies it to ~/Applications and links ~/.local/bin/juxta
```

Requires Xcode (Swift 5.10+), macOS 14+.

To make a copy that runs on other Macs, open `Juxta.xcodeproj` and choose Product → Archive, then
Distribute App → Direct Distribution. Xcode signs it with the Developer ID certificate and
notarizes it. `Sources/Juxta` is a synced folder, so new files show up in Xcode automatically.

## Using it

- **Open files:** drop one file on either pane (or two files on either pane), ⌘O to pick two,
  or the **Open…** button in each pane header. From Terminal: `juxta before.cfg after.cfg`.
- **Paste text:** ⌘V fills the first empty side, so you can paste `show run` from one device and
  then the other. Once both sides are filled, ⌘V replaces the focused pane. Use ⌥⌘V to paste
  on the left or ⇧⌥⌘V to paste on the right.
- **Navigate:** ⌥⌘↓ / ⌥⌘↑ (or `n` / `p`, `j` / `k` when a pane is focused), toolbar chevrons,
  or click anywhere in the change map on the right edge.
- **Colors:** blue = modified line (changed characters highlighted), red = removed,
  green = added, hatched = nothing on this side.
- **Options** (toolbar ⚙︎ or View menu): Ignore Whitespace, Ignore Case, Ignore Timers. These are
  remembered.
  - Ignore Timers compares the ages and uptimes in show output as equal: `00:12:44`, `1w2d`,
    `3w2d 04:11:22`, `2 weeks, 3 days`, `Last input never`. Timers that are bare numbers (EIGRP
    hold, ARP age) and counters still show; clock times with seconds are ignored too.
    `juxta-diff -t` does the same.
- **Font** (Juxta → Settings…, ⌘,): any installed monospaced font and typeface, size, line spacing,
  and ligatures (off by default, so a diff shows exactly which characters are in the file).
  Changes apply to every open window as you make them.
- ⌘R reloads both files from disk, ⌥⌘S swaps sides. ⌘+ / ⌘− make the text bigger or smaller in
  every window; ⌘0 (Actual Size) goes back to the size set in Settings.
- Click, shift-click or drag to select lines, double-click to select a whole change, ⌘C to copy.

### git difftool

```sh
git config --global difftool.juxta.cmd 'juxta -c "$LOCAL" "$REMOTE"'
git difftool -t juxta
```

`-c` copies the files first, because git deletes its temp files as soon as the command returns.
For added and deleted files, git passes `/dev/null` for the missing side; it is shown as an
empty file named `<file> (absent)`.

## How it works

- `Sources/JuxtaCore`: the diff engine (no UI). Lines are interned to integers, then aligned
  with patience anchoring on unique lines plus Myers O(ND) bisection within each region. Within
  a changed block, similar lines are paired up (bigram similarity) so they sit side by side,
  and changed characters are found with a second, character-level Myers pass.
  A 150k-line routing table compares in well under a second.
- `Sources/Juxta`: the AppKit UI. Each pane draws only its visible rows with Core Text, so
  scrolling cost doesn't depend on file size.
- `swift test` runs the engine tests (checked against a brute-force LCS).
- `Fixtures/` holds diff test pairs (encodings, line endings, config cases, large inputs);
  `docs/testing-plan.md` describes the testing plan.
- In debug builds, `JUXTA_SNAPSHOT=/tmp/shot JUXTA_STEPS=2 .build/debug/Juxta a b` writes PNGs
  of the composited window (initially and after each "next change") and then quits. This is handy for
  checking UI changes without screen-recording permission. `JUXTA_ACTIONS=next,prev,swap,reload`
  runs other steps, `JUXTA_DARK=1` uses Dark Mode, `JUXTA_HC=1` the Increase Contrast colors,
  and `JUXTA_AX=1` prints what VoiceOver
  sees (row labels, change map, announcements).
