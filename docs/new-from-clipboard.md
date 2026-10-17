# New Comparison from Clipboard (1.2)

Plan for a File menu item that starts a comparison from the clipboard. Written 2026-10-17.

## Why

⌘V fills the first empty side, so pasting two texts into one window already works. What's
missing is starting over once the front window is full: today that takes ⌘N, then ⌘V. A single
command makes paste-to-paste comparisons (`show run` from one device, then the other) quicker.

Menus say "Clipboard", as macOS does everywhere users see it; the code says pasteboard
(`NSPasteboard`).

## Behavior

- **File › New Comparison from Clipboard** (⇧⌘N) opens a new window with the clipboard text on
  the left, named "Pasted Text" like any paste. Copy the other text and ⌘V fills the right.
- If the clipboard holds file URLs (one or two files copied in Finder), it opens those files
  instead of comparing their names, the same as dropping them.
- The item is disabled when the clipboard has neither text nor file URLs.
- The Dock menu offers New Comparison and New Comparison from Clipboard.

## Changes

1. `MainMenu.fileMenu()`: add the item under New Comparison.
2. Move `clipboardText` out of `CompareWindowController` (an `NSPasteboard` extension, say) so
   `AppDelegate` can use it too.
3. `CompareWindowController`: expose a thin public wrapper over `setPastedText(_:on:)`.
4. `AppDelegate`: add `newComparisonFromClipboard(_:)`, which reads file URLs first, then text,
   and calls `openFiles` or `makeController()` plus the paste wrapper. Adopt
   `NSMenuItemValidation` to disable the item.
5. `AppDelegate.applicationDockMenu(_:)` with both New items.
6. README: one line under **Paste text**.

## Testing

- By hand: text on the clipboard, then one copied file, two copied files, and an image only
  (item disabled). Also try it from the Dock menu while Juxta is in the background.
- Optional: a `newFromClipboard` step in `JUXTA_ACTIONS` (`DebugSnapshot`) that sets the
  pasteboard first, so the snapshots cover it.

## Not in 1.2

- Filling both sides from clipboard history: there's no public API for it.
- A Services entry ("Compare Selection in Juxta"). It's a natural follow-up, but it needs
  `NSServices` in Info.plist and testing across apps.
