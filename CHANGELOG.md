# Changelog

Notable changes to Portico. Pre-1.0, minor versions may include breaking changes.

## [0.4.0] - 2026-07-02
### Added — the manga-lettering / headless-canvas surface (all additive)
Driven by Portico's first real client (MangaLoft text objects); plan + as-built record in
`Docs/MangaLettering-Extensions-Plan.md`, client recipe in `Docs/HeadlessRendering.md`.
- **`drawText(in:)`** — display-only render (no selection highlight, no caret). The
  raster/export counterpart of `draw(in:)`, which in vertical orientation always paints a
  caret when selection is empty. Output is independent of cursor/selection state.
- **`measuredSize(inlineExtent:)`** — content measurement sharing the exact layout attribute
  pipeline (WYSIWYG parity). `inlineExtent` = the wrap constraint along the writing direction
  (width horizontal / height vertical); nil = unconstrained; results ceiled; **verified-fit**
  (the engine end-verifies and repairs `CTFramesetterSuggestFrameSizeWithConstraints` in both
  directions — it over-reports the block axis under Portico's forced uniform pitch, and its
  historical failure mode is under-reporting). Valid on an engine that has never laid out.
- **`inkBounds()`** — union of glyph ink extents INCLUDING ruby readings (which overhang the
  layout rect on the ascent side) and the outline rim. Size raster tiles / selection chrome
  from this, not the layout rect. `.null` when nothing is painted.
- **`PorticoTextOutline`** + `engine.outline` — whole-text outline (縁取り/fuchi), drawn
  behind the fill with round joins. **`width` is the artist-facing rim thickness in points**
  (Core Text strokes center on the glyph path, so the stroke pass uses lineWidth = 2 × width
  and `inkBounds()` outsets by exactly `width`). Ruby readings are outlined too — Core Text
  does NOT propagate stroke attributes to `CTRubyAnnotation` glyphs, so the stroke pass
  rebuilds annotations carrying their own stroke attributes at the same absolute rim.
- **`linePitchMultiplier`** — scales the uniform ruby-reserving line pitch, clamped [0.5, 3];
  affects layout, measurement, and rendering identically. Note: in vertical orientation Core
  Text adds a small constant per-column leading on top of the pitch — the multiplier scales
  the pitch term, not the absolute column advance.
- Example app: outline toggle + width slider, pitch slider, live `measuredSize` readout.

## [0.3.0] - 2026-07-02
### Added
- **Undo / redo** across every edit — typing (coalesced into runs), delete, paste, cut, ruby
  (`setRuby`), and inline `《》` conversion. Driven by Edit ▸ Undo / ⌘Z / iOS shake. Undo is
  **model-scoped**: `PorticoTextLayoutEngine` owns a (default private, injectable) `UndoManager`,
  so history survives view teardown when you retain the engine.
- **`PorticoView(engine:)`** initializer — inject a client-owned engine for model-scoped undo (the
  existing `PorticoView(text:)` binding init keeps view-scoped undo). The engine also gains a public
  `setRuby(_:for:)` — the undoable ruby-edit command.

### Changed (breaking)
- `PorticoTextLayoutEngine` is now `@MainActor` (it owns a main-actor-isolated `UndoManager`; it was
  already main-thread UI state). `PorticoView`'s previously-public stored `text`/`orientation`
  properties are now private — use the initializers.

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
