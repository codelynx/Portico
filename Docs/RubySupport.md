# Ruby (Furigana) Support — Spec

Status: **Implemented** · Scope: **Display + Authoring + Editing** — the editing model
(apply/edit/remove, inline conversion, geometry) is specified in `Docs/RubyEditing-Design.md`.

## 1. Goal

Let Portico render ruby — small annotation text riding alongside base text
(Japanese furigana 振り仮名, also bopomofo / Korean) — and let callers author and
persist it as plain text using **Aozora Bunko notation**.

- Horizontal layout: ruby sits *above* the base.
- Vertical layout: ruby sits *to the right* of the base.

Core Text does the rendering. This spec is about the **notation ↔ attributed
string** boundary, not about drawing.

## 2. What we rely on (Core Text)

Ruby is attached to a base character range via the attribute
`kCTRubyAnnotationAttributeName`, whose value is a `CTRubyAnnotation`. Once
attached, `CTFramesetter` automatically:

- reserves space (inflates line ascent) for the ruby,
- draws the ruby in both orientations,
- keeps the ruby text *out of the backing string* — so string indices,
  hit-testing, caret rects, and selection fills in `PorticoTextLayoutEngine`
  need **no changes**.

## 3. Notation (Aozora Bunko)

A reading is written in double angle brackets `《 》` immediately after its base
text. Two ways to mark where the base begins:

| Form | Example | Base | Reading |
|------|---------|------|---------|
| Auto | `漢字《かんじ》` | preceding run of kanji | かんじ |
| Explicit | `｜大人《おとな》` | text after `｜`, up to `《` | おとな |

- **Auto-detection**: when there is no `｜`, the base is the maximal run of
  *kanji* (Unicode `CJK Unified Ideographs`, incl. the iteration mark 々)
  immediately preceding `《`.
- **Explicit `｜` (U+FF5C FULLWIDTH VERTICAL LINE)**: required when the base is
  not a pure kanji run (e.g. kana, Latin, mixed). The base is everything from
  `｜` up to the opening `《`.
- Granularity is **group-ruby**: the whole base maps to the whole reading. Mono-
  and jukugo-ruby nuances are out of scope for v1.

### 3.1 Edge cases (v1 policy)

- **No escaping.** Literal `《`, `》`, or `｜` in body text is *not* supported in
  v1 and is treated as control characters. Documented limitation.
- **Empty reading** `漢字《》` → no annotation attached; marks stripped.
- **Unmatched `《` without `》`** → left as literal text, no annotation.
- **`｜` with no following `《》`** → the `｜` is dropped (it only marks a base
  start); base text remains.
- **No base found** for an auto reading (e.g. `、《てん》`) → reading discarded,
  marks stripped, base text kept. (Conservative: never lose body text.)

## 4. Public API surface

The notation is the public surface. Two namespaced calls, both implemented:

```
// Parse Aozora notation into an attributed string with ruby annotations.
PorticoRuby.parse(_ notation: String, attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString

// Serialize an attributed string (with ruby annotations) back to notation.
PorticoRuby.serialize(_ attributed: NSAttributedString) -> String
```

- `parse` strips all ruby marks from the body, attaches a `CTRubyAnnotation`
  per base range, and applies `attributes` (font, color, …) to the whole string.
- `serialize` walks ruby annotations and re-emits marks, always using the
  **explicit `｜` form** on output (unambiguous regardless of base content), even
  where the input used auto-detection.
- Round-trip guarantee: `parse(serialize(x))` reproduces the same base text and
  readings; `｜` placement is normalized to the explicit form. (Base text holding
  literal `《`/`》`/`｜` can't round-trip — no escaping in v1 — but `parse` never
  produces such bases, so its output always round-trips.)

An internal primitive (not public in v1) does the actual attach:

```
// implementation detail
extension NSMutableAttributedString {
    func addRuby(_ reading: String, to range: NSRange, ...)
}
```

### 4.1 Client usage

Ruby is reachable from any client that links the library with a plain
`import Portico`. The authored string drops straight into the engine or the
SwiftUI view; uniform line-to-line pitch (§5.1) is applied automatically — the
client does nothing extra for it.

```swift
import Portico

// Author ruby from notation, then render it.
let text = PorticoRuby.parse("吾輩《わがはい》は猫《ねこ》である")

// SwiftUI:
PorticoView(text: .constant(text), orientation: .vertical)

// or drive the engine directly:
let engine = PorticoTextLayoutEngine(attributedString: text, orientation: .vertical)
```

A regression test (`PorticoRubyClientTests.swift`) exercises this path with a
non-`@testable` import, so the public surface stays intact.

## 5. Rendering defaults

Hard-coded sane defaults in v1, no public knobs yet:

- alignment: **center** (`.center`)
- overhang: **auto** (`.auto`)
- scale / sizeFactor: Core Text default (~0.5 of base)

These become parameters in a later phase if needed.

### 5.1 Uniform line-to-line pitch

Ruby normally inflates the height of the line that carries it, making the
line-to-line pitch uneven (デコボコ) next to ruby-free lines. To keep lines
evenly spaced, the layout engine reserves a **fixed line-to-line pitch on every
line**, sized to a ruby-bearing line and self-calibrated from the base font (no
tuning constant). Applied uniformly to all text the engine lays out — not just
parsed ruby — and in both orientations (line-to-line for horizontal,
column-to-column for vertical). The pitch is **merged into** any caller-supplied
paragraph style (alignment, indents, spacing are preserved), not overwritten.

**Known limitation:** Core Text does not fully contain a ruby annotation's
ascent within the line box, so a small residual (a fraction of a base line)
remains on ruby lines. This removes the bulk of the unevenness but is not
pixel-perfect. Exact uniformity would require manual per-line placement, which
is deferred (it would complicate the vertical `CTFrameDraw` path).

## 6. Out of scope (v1)

**Editing is now implemented** — apply/edit/remove (`setRuby`), inline notation conversion,
and geometry for tap/popover editing; see `Docs/RubyEditing-Design.md`. The chosen model is a
**hybrid**: the base is editable text, the reading a whole-value attribute (not an atomic
group), and inserting at a group boundary is plain text.

Still deferred:

- **Escaping** of control characters — `《`, `》`, `｜` in a base/reading don't round-trip.
- **Mono-ruby / jukugo-ruby** (per-character readings, cross-base overhang).
- **Public styling knobs** (alignment / overhang / scale).
- **Undo** integration; full **popover placement** (edge-avoidance) in the Example.

## 7. Phasing

1. **Parse + render** — `PorticoRuby.parse`, demonstrated in the Example app.
   ✅ Code + tests done (`PorticoRuby.swift`, `PorticoRubyTests.swift`).
   ✅ Visual rendering verified — macOS Example app, horizontal + vertical.
2. **Serialize** — round-trip to text → persistence.
   ✅ `PorticoRuby.serialize` + round-trip tests done.
3. **Editing** — apply/edit/remove (`setRuby`), inline notation conversion, tap/popover
   geometry. ✅ Done; hybrid model (editable base, whole-value reading) specified in
   `Docs/RubyEditing-Design.md`.

## 8. Files

- `Sources/Portico/PorticoRuby.swift` — parser, serializer, attach primitive, and the
  editing primitives (`setRuby`, `rubyGroup(at:)`, `rubyGroups(in:)`, `inlineRubyMatch`).
- `Tests/PorticoTests/PorticoRubyTests.swift` — parse, serialize, round-trip,
  §3.1 edge cases, and uniform line-to-line pitch.
- `Tests/PorticoTests/PorticoRubyEditingTests.swift` — editing: boundary rule, primitives,
  post-edit round-trip, inline conversion, geometry.
- `Tests/PorticoTests/PorticoRubyClientTests.swift` — public-API (non-`@testable`)
  smoke tests proving ruby is reachable from client code.
- Example app: renders ruby in both orientations and demonstrates the select→reading editor.
