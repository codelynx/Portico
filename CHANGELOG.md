# Changelog

Notable changes to Portico. Pre-1.0, minor versions may include breaking changes.

## [0.5.0] - 2026-07-04
### Added — 縦中横 (tate-chū-yoko), the automatic upright-in-vertical rule
Slice 4 of the manga-lettering arc (MangaLoft text objects v1 ship gate). Scope pinned at
the client's kickoff lock: **exactly-two half-width digits** not adjacent to another digit,
and **isolated half-width !?-family pairs** — rendered upright in one column cell. NO
markup, NO persistence change, NO host API: a pure detection rule re-derived from the text
on every relayout (CSS `text-combine-upright: digits 2` posture). Ruby-annotated ranges are
excluded (ruby wins). Explicitly NOT grouped: 3+-digit runs, Latin runs, full-width forms,
single-codepoint ‼⁇⁈⁉, anything horizontal.

- Groups measure, wrap, and line-break as ONE character cell; the extra-line-fragment and
  pitch behaviors compose unchanged.
- Fill AND outline (縁取り) render the upright pair; when a pair exceeds the column width
  the glyphs compress horizontally while the rim keeps its absolute artist-facing width.
- `inkBounds()` stays glyph-tight around groups (pinned at two sizes, plain + outlined).
- Editing: groups form/dissolve purely by re-detection (typing, backspace, paste, undo,
  setRuby all correct by construction); selection rects show the WHOLE cell for any
  intersecting range (visual only — the stored range stays per-character); a tap inside a
  cell snaps to the nearer boundary; the caret BETWEEN the pair's characters renders as a
  vertical bar in the group's local inline direction (device-witnessed); `wordRange(at:)`
  returns the group for probes inside it (double-click selects the pair); vertical
  column-hop navigation probes by column pitch (caret-shape-independent).
- Wrap-split is unreachable by construction for inline extents ≥ one character cell.

### Internal (NOT contract — hosts must not depend on layout-copy contents)
The mechanism lives entirely in the per-layout throwaway copy: `CTRunDelegate` cell
reservation (per-glyph advances), marker attributes, clear-fill + sub-pixel-font glyph
suppression, and same-length line-break stand-ins. The backing store, serialization,
typing inheritance, and every string-returning API never see any of it (leak-gated).

## [0.4.2] - 2026-07-04
Patch-class fixes to the shipped editing surface, all found by MangaLoft's slice-3 editor
integration + device gauntlet (real IME, Mac + iPadOS 26).

### Added
- **`typingAttributes`** — base attributes for text entering an EMPTY document (typing, the
  first IME keystroke, paste). Settable property AND `init` parameter; a non-empty seed
  string auto-captures its first run's attributes as the fallback (protects
  select-all → delete → type). Root cause of the reported "measuredSize divergence": the
  old empty-dictionary fallback made the first typed run lay out and measure at Core Text
  defaults instead of the host's font — `measuredSize` itself was deterministic all along.
  Head-of-document inserts now inherit from the FOLLOWING character (same fallback family).
- **`focusesOnMount`** on `PorticoTextView` / `PorticoView(engine:)` — claims first
  responder when the view lands in a window, for hosts that mount the editor
  programmatically (an in-place overlay opened by a tool gesture). Default off.

### Fixed
- **Return inserts a hard line break** (macOS): `doCommand(by:)` had no `insertNewline:`
  arm, so Return outside composition was silently dropped — multi-line text was
  unreachable from the keyboard. (Return during composition still confirms the conversion.)
- **Trailing hard break = extra line fragment**: the "next line" created by Return has no
  CTLine until a character lands on it — `measuredSize` now reserves one line pitch on the
  block axis and `caretRect` synthesizes the next line's head, so Return takes effect
  visibly at once (box grows; caret jumps to the new line/column top).
- **System caret conflict in vertical text on modern UIKit** (observed iPadOS 26): the
  tint-clearing trick no longer hides the system cursor view, so both the engine's vertical
  caret and UIKit's horizontal-text caret drew at once. While the engine owns the caret
  (vertical + no selection + no composition) the view now deactivates
  `UITextSelectionDisplayInteraction`; it reactivates the moment a selection or marked text
  appears, so native handles/highlight/IME UI are unaffected.

## [0.4.1] - 2026-07-02
### Fixed
- **`inkBounds()` now includes line-edge ruby reading overhang.** A reading wider
  than its base sitting at a line's first/last advance painted outside the
  reported ink rect (observed: line-final long reading in vertical; found by
  MangaLoft's integration containment test). The union now extends each
  line-intersecting ruby group's advance range by the reading's typographic
  overhang. Foreign (non-font) values under `.font` degrade to an approximation
  in this path rather than trapping.

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
