# 縦中横 override — per-range attribute, ruby-style (design DRAFT → Portico 0.6.0)

Owner-initiated (2026-07-04, after v1 shipped): the automatic rule covers the dominant
manga cases, but artists need intent control the rule can't infer — force-combine a
3-digit run ("123", "'26"), or un-combine an auto-detected pair for a specific
composition. The design mirrors ruby: a **persisted attribute** on the backing store, a
**selection-menu action** (the Example gains "縦中横" beside "Ruby…"), and an **owned
notation form** for serialization. The owner has explicitly freed the notation from
Aozora compatibility ("the format is ours to evolve" — recorded in the MangaLoft slice-4
plan).

## Model

One attribute key, ruby's shape:

```swift
PorticoTateChuYoko.overrideKey   // NSAttributedString.Key("PorticoTateChuYokoOverride")
enum TateChuYokoOverride: combine | suppress
```

- **`combine`** — the range renders as ONE upright cell in vertical text, regardless of
  the automatic rule (this is how "123" or "'26" get combined). Any length ≥ 1;
  the existing mini-line compression handles width (long runs compress unreadably —
  the artist's choice, same posture as extreme fonts).
- **`suppress`** — the range is excluded from automatic detection (an auto "12" the
  artist wants stacked). Precedence: suppress > combine > automatic; ruby still beats
  all (a ruby-annotated range is never TCY — unchanged v1 rule).
- Horizontal orientation: attribute is inert (persisted but no layout effect) — same as
  ruby's orientation-independence posture.
- **The `rotate` state from the original three-state sketch is DEFERRED**: rotate-vs-
  upright for lone characters is a different mechanism (glyph form, not grouping) and
  has no menu use-case yet. Two states now; the enum leaves room.

## Group derivation becomes one pure function

```
effectiveGroups(text, rubyRanges, overrides) =
    (automatic(text) − suppressed − rubyRanges) ∪ (combineRanges − rubyRanges)
```

Everything downstream (reservation, mini-line draw, ink, caret, selection, wordRange,
stand-in normalization) already consumes "the groups" — the derivation is the only
change point. Combine ranges of length 1 render as a one-glyph cell (upright lone
half-width digit — same as today's Hiragino default, so visually a no-op; accepted).

## Editing semantics (ruby parity)

- Typing at a combine range's boundary does NOT extend it (the ruby group-boundary rule,
  reused verbatim via `inheritedAttributes` stripping — the override key joins the
  strip list next to `rubyKey`).
- Deleting inside shrinks the range (NSMutableAttributedString native behavior).
- Applying/removing the override is an engine mutation with an undo step, exactly
  `setRuby`'s shape: `setTateChuYoko(_ override: TateChuYokoOverride?, for: NSRange)`.
- The selection menu toggles: selection inside an EFFECTIVE group (auto or combined) →
  "縦中横を解除" (applies `suppress` over an auto group, or removes `combine`);
  otherwise → "縦中横" (applies `combine`). One menu item, state-dependent title —
  ruby's prefill-or-create pattern.

## Notation (owned; Aozora-free by owner decree)

Serialize a `combine` range as **`〈…〉`** (U+3008/9 ANGLE BRACKETS): `〈123〉年` —
compact, typeable, visually light, and unlike ［＃…］ it reads inline. `suppress`
serializes as `〈/…〉`. Literal 〈〉 in body text joins the existing known limitation
(`《》｜` are already control characters — gap 9, same disposition). Parse/serialize
round-trip lives beside `PorticoRuby`'s.

- Auto-detected groups serialize as PLAIN TEXT (unchanged — automatic means automatic;
  only overrides carry notation).

## Example app

"縦中横" joins "Ruby…" through the SAME `PorticoSelectionMenuAction` seam — which today
carries exactly ONE action. The seam grows to an ARRAY (`onSelectionMenuActions:
[PorticoSelectionMenuAction]`, old single-action init kept as a convenience) — a small
breaking-adjacent change fenced to 0.6.0. The Example wires both actions; the TCY one
needs no popover (it's a toggle), making it the seam's simplest possible demo.

## Interactions audited

- **Stand-in normalization**: combine ranges > 2 chars get the same `あ・` treatment,
  generalized: first char `あ`, remaining chars `・` (ID NS NS… — internally unbreakable,
  boundary-safe both sides; same classes as the pair case).
- **Cell width**: one em regardless of length (JIS: TCY compresses INTO the column);
  compression factor grows with run length.
- **MangaLoft**: consumes automatically at render (provider re-measures) — but the
  MENU/inspector surface and `TextStyle`-level persistence questions are MangaLoft
  work, explicitly OUT of this Portico slice. The document model stores content
  strings; the override must survive MangaLoft's serialize path → it does, because
  content is serialized via `PorticoRuby.serialize` (notation carries it). Verify with
  an integration test when MangaLoft adopts.

## Slices (Portico 0.6.0)

1. **PR-1** — attribute + `effectiveGroups` derivation + editing semantics (boundary
   non-extension, undo, setTateChuYoko) + generalized stand-in. Rule/measure/editing
   test matrix incl. suppress-over-auto and combine-of-3.
2. **PR-2** — notation parse/serialize round-trip (`〈〉`, `〈/〉`) + leak/round-trip
   gates.
3. **PR-3** — multi-action menu seam + Example wiring (macOS + iOS) + 0.6.0 release.

## Open questions for review

- **OQ-A (menu toggle semantics)**: one state-dependent item vs two items
  ("縦中横" / "解除"). Draft: one, ruby-pattern.
- **OQ-B (suppress persistence)**: `suppress` on an auto pair persists as `〈/12〉` —
  or should suppress be modeled as "combine-range of length 0"… no: explicit enum is
  clearer. Confirm the two-state enum.
- **OQ-C (combine length cap)**: none (compression handles; artist's choice) vs cap at
  ~4 with a beep. Draft: none.
- **OQ-D (menu availability)**: horizontal orientation — hide the menu item, or allow
  (attribute inert until the object flips vertical)? Draft: allow + inert (the artist
  may flip orientation later; losing the intent would surprise).
