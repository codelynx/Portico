# Ruby (Furigana) Support — Spec

Status: **Design** · Scope: **Display + Authoring** (live-editing deferred)

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

The notation is the public surface. Two namespaced calls — `parse` ships in
Phase 1; `serialize` is **planned for Phase 2** (not yet implemented):

```
// Phase 1 — implemented.
// Parse Aozora notation into an attributed string with ruby annotations.
PorticoRuby.parse(_ notation: String, attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString

// Phase 2 — planned, not yet implemented.
// Serialize an attributed string (with ruby annotations) back to notation.
PorticoRuby.serialize(_ attributed: NSAttributedString) -> String
```

- `parse` strips all ruby marks from the body, attaches a `CTRubyAnnotation`
  per base range, and applies `attributes` (font, color, …) to the whole string.
- `serialize` (Phase 2) will walk ruby annotations and re-emit marks, always
  using the **explicit `｜` form** on output (unambiguous, lossless round-trip),
  even where the input used auto-detection.
- Planned round-trip guarantee: `serialize(parse(x))` *semantically* equal to `x`
  (same base text + readings), though `｜` placement may be normalized.

An internal primitive (not public in v1) does the actual attach:

```
// implementation detail
extension NSMutableAttributedString {
    func addRuby(_ reading: String, to range: NSRange, ...)
}
```

## 5. Rendering defaults

Hard-coded sane defaults in v1, no public knobs yet:

- alignment: **center** (`.center`)
- overhang: **auto** (`.auto`)
- scale / sizeFactor: Core Text default (~0.5 of base)

These become parameters in a later phase if needed.

## 6. Out of scope (v1)

Deferred to a future **editing** phase:

- Atomic-group deletion (deleting one base char removing the whole reading).
- Cursor-stepping policy across a ruby group.
- Typing into / splitting a ruby base range.
- Escaping of control characters.
- Mono-ruby / jukugo-ruby (per-character readings, cross-base overhang).
- Public styling knobs (alignment / overhang / scale).

The annotation survives in the attributed string under edits; we just don't yet
*guarantee* sensible behavior when a base range is partially edited.

## 7. Phasing

1. **Parse + render** — `PorticoRuby.parse`, demonstrated in the Example app.
   ✅ Code + tests done (`PorticoRuby.swift`, `PorticoRubyTests.swift`).
   ✅ Visual rendering verified — macOS Example app, horizontal + vertical.
2. **Serialize** — round-trip to text → persistence. _(next)_
3. **Editing semantics** — atomic group, cursor policy. (Future, separate spec.)

## 8. Files

- `Sources/Portico/PorticoRuby.swift` — parser + internal attach primitive
  (serializer added in Phase 2).
- `Tests/PorticoTests/PorticoRubyTests.swift` — parse + §3.1 edge cases
  (serialize / round-trip tests added in Phase 2).
- Example app: a sample string demonstrating ruby in both orientations.
