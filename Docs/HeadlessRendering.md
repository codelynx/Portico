# Headless rendering — the raster-service recipe

Portico's engine renders without any view. This is the contract a canvas host (the reference
client is MangaLoft's `TextRenderProvider`) builds on to paint committed text objects into its
own `CGContext` at arbitrary scale — live view, thumbnail, or high-DPI export.

## The recipe

```swift
// 1. Build (or fetch from your cache) an engine for the text object.
let engine = PorticoTextLayoutEngine(
	attributedString: PorticoRuby.parse(storedNotation), // + your style attributes
	orientation: .vertical,
	bounds: .zero
)
engine.linePitchMultiplier = style.linePitch          // optional
engine.outline = PorticoTextOutline(width: 2, color: rimColor) // optional 縁取り

// 2. Size the layout. measuredSize is valid before any layout exists.
let size = engine.measuredSize(inlineExtent: style.wrapExtent) // nil = point text
engine.update(bounds: size)

// 3. Draw into YOUR context at YOUR scale.
context.saveGState()
context.translateBy(x: 0, y: tileHeightPx)   // if your bitmap is top-left-origin:
context.scaleBy(x: scale, y: -scale)         // flip to Core Text bottom-left, then scale
engine.drawText(in: context)                 // display-only: no caret, no selection
context.restoreGState()
```

**Ink-sized tiles need an origin offset.** The transform above is exact for a tile covering the
LAYOUT rect (`tileHeightPx = scale × bounds.height`). But tiles should be sized from
`inkBounds()` (see Sizing below), and ink extends *outside* the layout rect — ruby past the
ascent side, an outline rim past all four sides (`ink.minX` is negative with an outline). For
a tile covering `paddedInk` (ink + your AA padding):

```swift
// Tile pixels: ceil(paddedInk.width × scale) × ceil(paddedInk.height × scale)
context.translateBy(x: -paddedInk.minX * scale, y: paddedInk.maxY * scale)
context.scaleBy(x: scale, y: -scale)
engine.drawText(in: context)
// Maps engine point p → ((p.x − paddedInk.minX)·scale, (paddedInk.maxY − p.y)·scale):
// the ink fills the tile exactly, rim and ruby included.
```

**Threading:** no view is required, but the engine is `@MainActor` — measure, `update(...)`,
and `drawText(in:)` are main-actor operations. This is a main-thread raster service, not a
thread-safe one; render off-main by rendering *into your own bitmap on main* and shipping the
bitmap.

Use **`drawText(in:)`**, never `draw(in:)`, for committed/display rendering — `draw(in:)` is
the *editing* renderer (selection highlight, caret; in vertical orientation it paints a caret
whenever there is no selection).

## Coordinates

The engine draws in **Core Text bottom-left** space covering `CGRect(origin: .zero, size:
bounds)`. It never touches the context transform — the client owns it entirely:

- **Bottom-left bitmap** (rare): just `scaleBy(scale, scale)`.
- **Top-left bitmap** (the common case; what `PorticoTextView` does on iOS): translate by the
  pixel height, then scale with negative Y — as in the recipe above.

Because text re-lays out from vectors, any scale renders crisp; there is no "native"
resolution.

## Sizing: layout rect vs ink

- `measuredSize(inlineExtent:)` — the **layout rect**: what you pass to `update(bounds:)` and
  persist. Verified-fit (the engine end-verifies against `CTFrameGetVisibleStringRange`).
- `inkBounds()` — the **painted extent**: ruby readings overhang the layout rect on the ascent
  side (above in horizontal, right of the column in vertical), and an outline extends it by
  its width. **Size raster tiles and selection chrome from `inkBounds()`,** converted to your
  target scale and outset ~1px for antialiasing — never clip exactly to it, and never clip to
  the layout rect.
- `inkBounds()` returns `.null` for no layout or no painted glyphs; keep a layout-rect
  fallback for degenerate content.

## Reuse, caching, and invalidation

A retained engine is a valid raster service (verified by `PorticoHeadlessTests`):

- Repeated `drawText(in:)` at different context scales is geometrically consistent.
- Editing state (`cursorIndex`, `selectionRange`) does not affect `drawText` output — a
  cached engine can't leak editor state into export.
- `update(attributedString:)` / `update(bounds:)` / `update(orientation:)` /
  `linePitchMultiplier` relayout; `outline` changes invalidate the internal stroke frame.
  All internal — the client never manages render caches beyond keeping/dropping engines.

Cost model: every content/bounds/orientation/pitch change rebuilds the full `CTFramesetter` +
`CTFrame` (no incremental layout), and each `measuredSize` framesets per call. At
dialogue-length strings this is cheap (a per-keystroke measure is fine); don't hold hundreds
of live engines for *display* — cache your rasters and re-instantiate engines on demand.

One live **view** per engine (`PorticoView`'s repaint slot is single); any number of headless
draws is fine.

## Platform note

The engine's CG code is platform-shared; the package test suite runs on macOS and covers the
render surface pixel-level. The only per-platform difference a client sees is the flip
convention of its own target context (see Coordinates above). The Example app doubles as the
manual smoke for both platforms (outline toggle, pitch slider, live measurement readout).
