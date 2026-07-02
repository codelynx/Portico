# Changelog

Notable changes to Portico. Pre-1.0, minor versions may include breaking changes.

## [Unreleased]
### Fixed
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
