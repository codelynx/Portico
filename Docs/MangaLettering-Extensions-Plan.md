# Manga-lettering extensions — implementation plan (slice 1 of MangaLoft text objects v1)

Status: **PLAN REV 2 — implementation phase ("how"). Review round folded 2026-07-02
(3 reviewers: approve with corrections; all folded below). Drafted against v0.3.0 (`554cda5`).
Ready to execute on user go.**

Portico's first real client is MangaLoft's text-object system
(`MangaLoft/docs/plans/text-objects-v1-kickoff.md`, LOCKED 2026-07-02). That design renders
committed text through a headless engine (a `TextRenderProvider` draws into Metalia's
CGContext) and edits through `PorticoView(engine:)` in a canvas overlay. The kickoff's gap memo
(§4) assigns Portico five work items as **slice 1** — all engine-surface extensions, all
testable in this repo's tests + Example app before MangaLoft consumes any of them.

**Design principles for this slice:**

- **Additive only.** No breaking API changes; `draw(in:)` behavior is unchanged by default.
  Target release: **0.4.0**.
- **WYSIWYG parity is the invariant.** Anything that affects committed rendering (outline,
  line pitch) must affect the editing render and measurement identically — one prepared-string
  pipeline (`layoutReadyString()`), three consumers (edit draw, display draw, measure).
  Parity lives in the *prepared string + frame attributes*, NOT in sharing a framesetter
  object — framesetter reuse is a cache optimization to consider only if PR-6's tests show it
  matters (dialogue-length strings framesetted per call are cheap).
- **Test posture (applies to every PR):** no golden image files and no cross-build
  byte-identity claims — font rasterization drifts across OS releases. "Unchanged" is proven
  by **in-process A/B** (old path vs new path rendered in the same run: multiplier 1.0 vs
  baseline, nil outline vs baseline). Pixel assertions use sampling/coverage counts with
  tolerances at robust offsets, never exact equality at AA edges. Coverage matrix: H + V,
  ruby, **long-reading ruby** (reading wider than base), outline, marked text, 1×/2×/8× scale
  reuse. macOS-only SwiftPM test runs are acceptable — the CG code is platform-shared; the one
  platform divergence (context flip convention) is documented in PR-6's guide, with a manual
  iOS Example-app smoke at release.
- **Branch policy (unanimous review): introduce `develop` at PR-1.** MangaLoft consumes
  Portico by local path — whatever is checked out is what the app builds — so `main` must stay
  a known-good, releasable/taggable checkout. Metalia-style flow: `feature/…` → `develop`
  (`--no-ff`), release merge `develop` → `main` + tag `0.4.0`.
- **No 縦中横 here** (MangaLoft slice 4; automatic rule, no markup). **No per-range style
  commands, no shape containers, no ruby styling knobs** — deferred by the kickoff.

**PR order (re-sequenced per review): PR-1 → PR-2 → PR-5 (inkBounds core) → PR-3 → PR-4
(outline, + inkBounds outset) → PR-6.** PR-1/2/5 unblock MangaLoft slice 2 together — its
touch list needs measurement AND `tightVisualBounds(of text:)` at the same moment; PR-5's only
tie to outline was the outset, which moves into PR-4.

---

## PR-1 — Display-only render: `drawText(in:)` (kickoff gaps 3 + 11)

**Problem:** `draw(in:)` is an *editing* renderer: selection highlight + (in vertical,
unconditionally) a caret (`drawsCaret`, `PorticoTextLayoutEngine.swift:44`) — a committed
vertical text object rendered headlessly shows a spurious caret.

**Change:** add

```swift
/// Renders the laid-out text only — no selection highlight, no caret.
/// The display/raster-export counterpart of `draw(in:)`. No layout
/// (zero bounds) = no-op. When an outline is set (0.4.0), includes the
/// outline pass — outline is part of the text, not editing chrome.
public func drawText(in context: CGContext)
```

**Layering correction (review):** the current order is selection **under** text, caret
**over** text (`draw(in:)` at `:907`). Decompose into three privates preserving that order —
`drawSelection` → `drawTextCore` → `drawCaret` — with `draw(in:)` = all three (unchanged
behavior) and `drawText(in:)` = `drawTextCore` only. Do NOT describe or implement this as
"drawText then chrome": that would paint selection over glyphs. Note: `draw(in:)` paints no
marked-text chrome today (marked-text styling, if any, lives in string attributes), so
`drawText`'s doc comment makes no claim about it.

**Acceptance / tests:**
- Vertical engine, no selection: `draw(in:)` output ≠ `drawText(in:)` output in-process (caret
  pixels present in the former only); `drawText` output invariant under `cursorIndex` changes.
- In-process A/B: `draw(in:)` before/after the refactor decomposition renders identically
  (same run).
- `drawsCaret` doc comment cross-references `drawText(in:)` as the display path.

Size: **tiny**. Branch setup (`develop`) happens here.

## PR-2 — Content measurement: `measuredSize(inlineExtent:)` (kickoff gap 1)

**Problem:** layout requires client-supplied `bounds`; no "how big is this text?" API.
MangaLoft needs it for point-text auto-grow, boxText block-extent measurement, §3.6
stale-layout re-measure, and raster tile sizing.

**Change:** extract the layout-string preparation in `updateLayout()`
(`PorticoTextLayoutEngine.swift:849` — pitch merge + `.verticalGlyphForm`) into a private
`layoutReadyString()` used by BOTH layout and measurement, then add

```swift
/// Measures the content's natural LAYOUT size (the rect to lay out /
/// store — NOT ink extents; ruby overhang and outline live in
/// `inkBounds()`). `inlineExtent` is the wrap constraint along the
/// writing direction — width when horizontal, height when vertical;
/// nil = unconstrained (manual line breaks only). Ceiled to integral
/// points. Independent of current `bounds`; valid on an engine that
/// has never laid out.
public func measuredSize(inlineExtent: CGFloat? = nil) -> CGSize
```

Implementation: `CTFramesetterSuggestFrameSizeWithConstraints` on a framesetter built from
`layoutReadyString()`, same `kCTFrameProgression` frame attributes; inlineExtent maps to width
(H) / height (V), other axis huge; **ceil** (fractional sizes round-trip badly through
persisted `layoutSize`).

**Stated fallback (review):** `CTFramesetterSuggestFrameSizeWithConstraints` is historically
unreliable under forced `minimum/maximumLineHeight` — exactly what the uniform ruby pitch
applies. The tightness acceptance below detects it; ship a fallback if the primary fails
acceptance; don't stall.
**AS BUILT (post code review):** the unreliability materialized exactly as predicted (vertical
block axis overreported by >2pt; caught by the tightness test). Shipped as **end-verify both
directions + binary-search tighten**: (1) the suggestion is end-verified and repaired UP if it
under-reports (the historically reported failure mode; sanity-bounded, debug-asserted); (2) the
block axis is binary-searched down between the `lineCount × pitch` floor and the known-fitting
size (fit is monotone; Core Text adds sub-point per-line leading pure pitch arithmetic
misses). The tighten is skipped as a PERF guard — not correctness, end-verification guarantees
fit regardless — when caller block spacing (`paragraphSpacing`/`paragraphSpacingBefore`/
`lineSpacing`, which CT applies even under clamped line heights) puts the floor uselessly low
(`hasBlockSpacingBeyondPitch`). Non-finite/non-positive `inlineExtent` = unconstrained
(documented). Also: the "reflects paragraph alignment" acceptance became a documented
**alignment-neutrality** claim — intrinsic measurement doesn't change with alignment; that's
the truthful semantics.

**Acceptance / tests:**
- For H and V, with and without ruby (incl. long-reading ruby): layout at `measuredSize()`
  shows the full string (frame visible range == string length), and shrinking either dimension
  by 2pt truncates (tightness).
- **Works with no prior layout**: correct result on a fresh engine whose bounds were never
  nonzero (`updateLayout()` bails on zero bounds — measurement must not depend on it).
- Constrained: wraps within inlineExtent; block extent grows with content.
- Reflects `linePitchMultiplier` (PR-3, once landed) and paragraph alignment.
- Empty string → `.zero` (documented).

Size: **small**. (The `layoutReadyString()` extraction is the load-bearing part.)

## PR-5 — Ink bounds: `inkBounds()` (kickoff gap 12) — **moved up: lands 3rd**

**Problem:** MangaLoft's selection frame wants glyph-hugging bounds
(`tightVisualBounds(of text:)` in its slice 2), and the never-clip raster posture needs "how
far does ink extend", including ruby overhang.

**Change:**

```swift
/// Union of the laid-out glyphs' ink extents, INCLUDING ruby reading
/// glyphs. (From 0.4.0-PR-4: also outset by the outline width when
/// set.) Engine (Core Text bottom-left) coordinates; `.null` when
/// there is no layout.
public func inkBounds() -> CGRect
```

Implementation: iterate `textFrame` lines + origins;
`CTLineGetBoundsWithOptions(.useGlyphPathBounds)` per line, mapped **line-local → engine rect
by an orientation-specific mapper** — in vertical mode line origins advance visually downward
with Y subtracted (see the existing mapping at `:752`); a naive `origin + bounds` union is
wrong in vertical. The mapper is a named private function with its own geometry tests.
**Skip null bounds** (empty lines `\n\n` yield null glyph-path bounds; unioning them degrades
the result).

**R2 verification + corrected fallback (review):** verify whether ruby annotation extents are
included in glyph-path line bounds. **The old fallback (union `rects(forRubyGroupContaining:)`)
is insufficient — those are BASE-glyph selection rects (`:763`), not reading-glyph extents; a
long reading overhangs them.** If R2 fails, the fallback must derive actual reading extents:
per ruby group, measure the reading string at ruby scale (~0.5 × base size, matching
`CTRubyAnnotation`'s sizing) positioned on the ruby side of the base rect — or, bluntly,
compute painted-alpha bounds in a scratch raster for the affected lines. Long-reading test
gates whichever path ships.

**Acceptance / tests:** inkBounds ⊆ layout bounds for plain text with margins; ruby grows the
**top** bounds in horizontal and the **right** bounds in vertical (geometry assertions);
long-reading ruby (reading wider than base) fully contained; empty-line documents don't
degrade the union; V + H both covered.

**AS BUILT: R2 resolved — ruby IS included in `CTLineGetBoundsWithOptions(.useGlyphPathBounds)`**
(the ruby-growth geometry tests pass natively on both axes); the reading-extents fallback was
never needed. The orientation-specific mapper (`lineLocalToEngineRect`, mirroring
`selectionRects`' vertical mapping) is validated pixel-level by a containment test: every
non-transparent pixel `drawText(in:)` paints — ruby included, both orientations — falls inside
`inkBounds()` (±1.5px AA slop).

Size: **medium** (was small–medium; the vertical mapper + real ruby fallback are the work).

## PR-3 — Line-pitch control: `linePitchMultiplier` (kickoff gap 4)

**Problem:** `updateLayout()` force-overwrites min/max line height with the uniform
ruby-derived pitch (`:866-876`); clients cannot adjust leading.

**Change:**

```swift
/// Scales the uniform ruby-reserving line pitch. 1.0 (default) =
/// current behavior; < 1 tightens (ruby may overlap the previous
/// line — client's judgment), > 1 loosens. Clamped to [0.5, 3].
/// Triggers relayout on change.
public var linePitchMultiplier: CGFloat = 1.0
```

Applied at the single `rubyLinePitch()` consumption site. Ruby-uniform pitch stays the
default — an override knob, not a new spacing model.

**Acceptance / tests:** line-origin spacing scales linearly with the multiplier (via
`lineOrigins()`); `measuredSize` tracks it; 1.0 is identical to baseline **in-process A/B**.

Size: **small**.

## PR-4 — Outline / 縁取り text (kickoff gap 2) + inkBounds outset

**Problem:** rendering is fill-only; manga needs halo/edge lettering over artwork.
Object-level (whole-text) outline suffices per the kickoff.

**Change:**

```swift
/// Whole-text outline (縁取り). `width` is the ARTIST-FACING fuchi
/// thickness in points — the visible rim outside the glyph edge.
/// Because Core Text strokes are centered on the glyph path, the
/// stroke pass uses lineWidth = 2 × width, and `inkBounds()` outsets
/// by `width`. Non-finite or ≤ 0 width == no outline. Drawn BEHIND
/// the fill; affects `draw(in:)`, `drawText(in:)`, and `inkBounds()`.
public struct PorticoTextOutline: Equatable {
	public var width: CGFloat
	public var color: CGColor
}

public var outline: PorticoTextOutline?   // nil = off (default)
```

**Value-semantics pins (review):** width defined as fuchi thickness (above) — locked before
0.4.0 so the 2× isn't discovered later; `width ≤ 0`/NaN/∞ behaves as off; **no `Sendable`**
(CGColor isn't Sendable and the engine is `@MainActor` — the conformance buys nothing);
`Equatable` implemented explicitly with `CFEqual` on colors. Setting/changing `outline`
(including color-only changes) **invalidates the cached stroke frame and repaints**, same
contract as `linePitchMultiplier`'s relayout-on-change.

Implementation: two-pass draw inside `drawTextCore`. Pass 1 = stroke-only frame:
`layoutReadyString()` copy with `.strokeWidth` **positive** (stroke-only; percent-of-font-size
semantics — convert from points **per run's font size**, even though MangaLoft v1 styles are
uniform) + `.strokeColor`, framesetted once and cached alongside `textFrame` (same
invalidation events + outline changes). Pass 2 = normal fill frame. **Round line join** — the
default miter join produces spiked halos at sharp glyph corners, exactly the manga-fuchi
failure mode.

**Known risk R1 (investigate first, in this PR):** whether `CTRubyAnnotation` glyphs pick up
the base run's stroke attributes in the stroke pass. If not, the stroke pass rebuilds ruby
annotations carrying stroke attributes — **acceptance requires outlined ruby** (furigana over
artwork needs the halo as much as the base text).

**AS BUILT: R1 answered NO** — the `rubyIsOutlined` pixel gate showed zero rim pixels in the
ruby band with base-run stroke attributes alone; Core Text does not propagate them to
annotation glyphs. **The fallback shipped:** the stroke pass rebuilds each annotation
(reading via `CTRubyAnnotationGetTextForPosition`, scale via `CTRubyAnnotationGetSizeFactor`,
center/auto/before re-asserted — Portico's single mint site) carrying its own stroke
attributes with the percent computed against the ruby font size, so the reading gets the same
ABSOLUTE rim as the base. The stroke/fill line-origin parity assertion passes WITH the rebuilt
annotations — the rebuild does not perturb layout.

**Acceptance / tests:** with outline set, coverage sampling at a robust offset outside the
glyph edge shows outline color (H + V, with ruby incl. long readings); fill color unchanged at
glyph interiors (outline behind fill); `draw` and `drawText` agree; nil outline identical to
baseline **in-process A/B**; **stroke-frame line origins == fill-frame line origins** (stroke
attributes must not change advances — this is the load-bearing two-frame assumption, and it
also guards the R1 fallback against perturbing layout); `inkBounds()` grows by exactly `width`
per side.

Size: **medium** (R1 is the variable).

## PR-6 — Headless-rendering guide + reuse verification (kickoff gap 13) + release

No new API expected. (a) Tests: one retained engine, repeated `drawText` at 1×/2×/8× scaled
bitmap contexts → identical geometry modulo scale (sampling with tolerance, not byte diffs);
no state leakage from cursor/selection churn between draws; `update(attributedString:)`
invalidates correctly. (b) New `Docs/HeadlessRendering.md`: the provider recipe (build engine →
`update(bounds:)` → scale/flip context → `drawText(in:)`), per-platform flip conventions (the
one true platform divergence — tests are macOS-run, code is shared; documented as such), cost
model (full reframe per content/bounds change; framesetter-per-call measurement is fine at
dialogue scale), the one-live-view-per-engine constraint. (c) CHANGELOG + bump + merge
`develop` → `main` + tag **0.4.0**; Example app gains demo toggles (outline on/off + width,
pitch slider, auto-size-to-content) — doubles as the manual iOS smoke.

**Slice exit checklist (MangaLoft-facing):** with public API only, a provider can measure
(constrained + unconstrained, incl. never-laid-out engine), lay out, render display-only
vertical text with long-reading ruby and outline at 8× with zero caret/selection artifacts,
and query ink bounds containing every painted pixel. All 128 pre-existing tests green.

**AS BUILT (slice exit):** checklist met — 170 tests green (128 pre-existing + 42 new across
PR-1..6). iOS smoke status: Example app **builds** for iOS Simulator (iPhone 16/18.6) and
macOS with the 0.4.0 demo controls; the *interactive* pass (IME typing, ruby editing, outline toggle,
pitch slider by hand) was run and confirmed by the user on device 2026-07-02 — **iOS smoke
GREEN**; the earlier waiver is closed. Guide gained the ink-sized-tile origin-offset recipe and the
`@MainActor` threading note (round-8 review).
