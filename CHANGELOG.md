# Changelog

Notable changes to Portico. Pre-1.0, minor versions may include breaking changes.

## [0.2.2]
### Fixed
- iOS: the client's selection-menu action (e.g. "Ruby…") was buried below the fold on the long
  edit menu once the clipboard actions filled `suggestedActions`. It's now placed first, in its
  own inline group, so it stays visible.

## [0.2.1]
### Fixed
- iOS: after Cut / Delete / Paste (and backspace or typing over a selection), the native
  selection grab-handles lingered over the deleted span — the text updated but the selection UI
  didn't. Mutations that replace a selection now also send `selectionWillChange`/`selectionDidChange`
  so `UITextInteraction` dismisses the handles to a caret.
- iOS `replace(_:withText:)` with a **zero-length** range (UIKit uses these for QuickType /
  point insertions) inserted at the old cursor instead of the range's location, a regression
  from the 0.2.0 `selectionRange` normalization. It now routes through `setSelectedRange(_:)`.

## [0.2.0]
### Added
- **Unified ruby-editing UX**: select text → native edit action → prefilled popover (iOS
  `UITextInput.editMenu(for:suggestedActions:)`, macOS context menu + `Edit ▸ Ruby…` / ⇧⌘R),
  via the client seam `PorticoSelectionMenuAction` on `PorticoView`.
- **Clipboard** on both platforms (cut / copy / paste / select all). Copy serializes the
  selection to Aozora notation and Paste parses it, so ruby round-trips copy/paste.
- **Minimal ruby notation** on `serialize` — omits `｜` when auto-detection recovers the base.
- **Orientation-aware iOS arrow-key navigation** (line/column moves) and Shift+Arrow selection.
- `PorticoTextLayoutEngine.anchorRectForSelection()` — first-segment popover anchor for any selection.

### Removed (breaking)
- `PorticoTextLayoutEngine.rubyAnchorRectForSelection()` — replaced by `anchorRectForSelection()`,
  which also handles plain (non-ruby) selections.
- `PorticoView`'s `rubyGroupAnchor` binding parameter — superseded by the selection-menu seam.

### Changed
- `selectionRange` normalizes a zero-length value to `nil`. Place a caret or selection via
  `setSelectedRange(_:)`; a raw `selectionRange = NSRange(location:, length: 0)` no longer stores a location.

## [0.1.0]
- Initial tagged release: Core Text engine with horizontal + vertical Japanese layout,
  hit-testing, selection, IME (macOS + iOS), and ruby (furigana) display + editing.
