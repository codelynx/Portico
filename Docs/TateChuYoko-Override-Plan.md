# 縦中横 override — per-range attribute, ruby-style (REV 2, review folded → Portico 0.6.0)

Owner-initiated (2026-07-04, after v1 shipped): the automatic rule covers the dominant
manga cases, but artists need intent control the rule can't infer — force-combine a
3-digit run ("123", "'26"), or un-combine an auto-detected pair for a specific
composition. The design mirrors ruby: a **persisted attribute** on the backing store, a
**selection-menu action** (the Example gains "縦中横" beside "Ruby…"), and an **owned
notation form** for serialization. The owner has explicitly freed the notation from
Aozora compatibility ("the format is ours to evolve" — recorded in the MangaLoft slice-4
plan).

## Foundational invariant (OWNER-RATIFIED 2026-07-04)

**The `NSAttributedString` is the model; notation is only an encoding.** Ruby, the TCY
override, and every future Japanese-typesetting annotation (圏点/kenten, 割注/warichu,
傍線…) live as ATTRIBUTES on the attributed string — one new attribute key + one
notation keyword per kind, forever. Layout/editing/undo/rendering read attributes and
never touch notation. This is the attribute-span model the survey's engineered systems
(InDesign, Word, CSS, TTML) converge on.

Corollaries:
- **Aozora `《》` is a ONE-WAY import filter** (`parse(aozora:)` → ruby attributes);
  nothing ever emits `《》`. It is a conversion courtesy, not a representation.
- **Automatic TCY stays DERIVED, never stored** — the string carries only OVERRIDES
  (artist intent); the automatic rule remains a pure function of the text at layout
  time, so documents ride rule improvements for free.

## Model

One attribute key, ruby's shape:

```swift
PorticoTateChuYoko.overrideKey   // NSAttributedString.Key("PorticoTateChuYokoOverride")
// REV 2 (review Major, load-bearing): the value is a CLASS-BOXED object
// carrying per-application IDENTITY, not a plain enum — NSAttributedString
// COALESCES adjacent runs with equal values, so a bare enum would merge an
// artist's "12"+"34" into one "1234" cell. Ruby dodges this only by the
// accident of CTRubyAnnotation reference identity; the parity must be
// deliberate here.
final class TateChuYokoOverride { enum Kind { case combine, suppress }; let kind: Kind }
```

**Range surgery (review fold):** `setTateChuYoko(_:for:)` CLEARS/TRIMS intersecting
override spans before applying (ruby's range-surgery template); a partial overlap
replaces the intersection cleanly. **Nesting is explicitly REJECTED in v1** — no ruby
inside a combine or vice versa (precedence handles overlap; the grammar below also
refuses to express nesting, avoiding parse/serialize asymmetry).

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
effectiveGroups (REV 2, normalized — review Major):
  1. ruby ranges remove first;
  2. ANY explicit override MASKS every intersecting automatic group;
  3. suppress contributes no group;
  4. combine contributes its non-ruby fragments.
  GUARANTEE: sorted, non-overlapping output (a combine over "1" next to auto
  "12" can't yield overlapping [0,2]+[0,1]).
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

## Notation — REDESIGN SCOPE WIDENED (owner, 2026-07-04)

The owner dislikes the Aozora ruby markup itself ("doesn't sound like designed by
computer scientists") — the notation question now covers RUBY TOO, not just the TCY
override. Reference survey of how engineered systems mark these up:

### How others do it

| System | Ruby | 縦中横 (TCY) | Model |
|---|---|---|---|
| **HTML/CSS** | `<ruby>漢字<rt>かんじ</rt></ruby>` (+`<rp>` fallback) | `<span style="text-combine-upright: all">12</span>`; CSS `digits <n>` = the automatic rule | Structured element / style property |
| **Adobe InDesign (tagged text)** | `<cRuby:1><cRubyString:かんじ>漢字<cRuby:>` | `<cTatechuyoko:1>12<cTatechuyoko:>` | **Attribute-span tags** — open/close attribute scopes, machine-oriented |
| **Word / OOXML** | `<w:ruby>` element (rubyPr + rt + rubyBase) | run property `<w:eastAsianLayout w:combine="true"/>` | XML run properties |
| **LaTeX (pxrubrica / pLaTeX)** | `\ruby{漢字}{かんじ}` | `\rensuji{12}` / `\tatechuyoko{12}` | Command + braced arguments |
| **Unicode interlinear** | U+FFF9 漢字 U+FFFA かんじ U+FFFB | — | Control characters (engineered, but invisible = untypeable/undebuggable; little adoption) |
| **でんでんマークダウン** (EPUB) | `{漢字|かんじ}` | inline HTML fallback | Minimal delimited pair |
| **pixiv novels** | `[[rb:漢字 > かんじ]]` | — | **Namespaced double-bracket command** |
| **カクヨム / なろう** | `｜漢字《かんじ》` (Aozora-derived) + `《《傍点》》` | — | Transcription-convention lineage (the style being rejected) |
| **TTML/IMSC (broadcast)** | `tts:ruby="base/text/container"` | `tts:textCombine="all"` | XML attributes |

### The engineering read

Professionally-designed systems converge on TWO models: **attribute spans** (InDesign,
Word, TTML, CSS — the annotation is styling scoped to a range, exactly Portico's
in-memory model already) and, for plain text, **a uniform command grammar** with the
base and annotation both explicitly delimited (LaTeX, pixiv, denden). Aozora's
`｜…《…》` is neither: it's a reading convention with implicit base detection, no
escaping (Portico gap 9 exists BECAUSE of it), and no extension point — every new
annotation type needs new punctuation.

### Recommendation: one namespaced span grammar for ALL annotations

```
[[ruby:漢字|かんじ]]     ruby
[[tcy:123]]              force-combine
[[tcy-off:12]]           suppress-combine (REV 2: was [[tcy/:12]] — all three
                         reviewers rejected the bare slash as parser punctuation
                         leaking into authoring; -off is greppable and readable)
future: [[em:強調]] (圏点), [[warichu:…]], …
```

- **One grammar, open namespace** — new annotation kinds cost a keyword, not new
  punctuation (the pixiv insight, generalized).
- **Explicit base** — no implicit base-detection heuristics (the `｜` hack dies).
- **Escapable by design — FULL grammar spec required at PR-2 entry (review fold)**:
  escapes for `\[[`, `\]]`, `\|`, `\\`; defined behavior for malformed commands,
  trailing backslash, and nested-command refusal. Round-trip PROPERTY tests written
  FIRST (serialize∘parse = identity over payloads containing `[[`, `|`, `]]`, mixed
  ruby+tcy) — Aozora-Portico's one great property, proven before anything rides on it.
- **The ecosystem argument (review fold)**: pixiv's `[[rb:…]]` proves double-bracket
  span grammar is already native to Japanese amateur writing — this is the ecosystem's
  own convention with a cleaner separator, not engineer-brackets imposed on JP prose.
  (LaTeX-style has a JP-specific strike: on JIS keyboards backslash IS the ¥ key.)
- **ASCII delimiters** — typeable on any keyboard, greppable, diff-friendly; the
  payload stays Japanese.
- Pre-1.0 no-migration posture (REV 2, review-unanimous): `serialize` emits ONLY the
  new grammar; the DEFAULT `parse` is a clean break (carrying `《》` in the default
  path would smuggle gap 9's no-escaping disease into the new era). Aozora survives
  as a separate, explicitly-named import entry point (`parse(aozora:)`) — a
  quarantined conversion utility for existing corpora.
- **The notation surface gets its own type (review fold): `PorticoNotation`** —
  serialize/parse for ALL annotations; `PorticoRuby`-named entry points remain as
  compatibility sugar only.

Auto-detected TCY groups still serialize as PLAIN TEXT (automatic means automatic;
only overrides carry notation).

## Example app

"縦中横" joins "Ruby…" through the menu seam — which grows to an **action PROVIDER**
(REV 2, review fold): actions are evaluated AT MENU-OPEN TIME with the selection
context, because the TCY title is state-dependent ("縦中横" / "縦中横を解除"). The old
single-action init wraps the provider. Toggle semantics (review fold): mixed-state
selection resolves APPLY-WINS (bold-editor convention — applying normalizes the whole
selection into one span); choosing 縦中横 on a suppressed range REMOVES the suppress
(never a suppress-still-wins surprise). The Example wires both actions; the TCY one
needs no popover.

## Interactions audited

- **Stand-in normalization**: combine ranges > 2 chars get the same `あ・` treatment,
  generalized: first char `あ`, remaining chars `・` (ID NS NS… — internally unbreakable,
  boundary-safe both sides; same classes as the pair case).
- **Cell width**: one em regardless of length (JIS: TCY compresses INTO the column);
  compression factor grows with run length.
- **MangaLoft**: consumes automatically at render (provider re-measures) — but the
  MENU/inspector surface and `TextStyle`-level persistence questions are MangaLoft
  work, explicitly OUT of this Portico slice. The document model stores content
  strings; the override survives MangaLoft's serialize path only through
  **`PorticoNotation`** (PR-3 switched the clipboard/serialization seams off the
  Aozora path, which cannot carry TCY). Verify with an integration test when
  MangaLoft adopts.

## Slices (Portico 0.6.0)

1. **PR-1** — identity-boxed attribute + normalized `effectiveGroups` + range surgery
   + editing semantics + generalized stand-in **with its own force-wrap sweep** (the
   [ID][NS][NS]… no-break argument is plausible; this arc doesn't ship plausible).
   Test matrix: suppress-over-auto, combine-of-1/2/3/5+/ugly-long, ADJACENT combines
   stay distinct cells (the coalescing pin), 3+ interaction rows (interior tap snaps
   to the NEAREST mini-glyph boundary — the half rule generalizes; caret/selection/
   wordRange/delete/undo at 3+).
2. **PR-2** — the NEW notation: `[[…]]` grammar parse/serialize for ruby AND tcy,
   escaping, round-trip + leak gates; decide Aozora-parse-compat at review.
3. **PR-3** — multi-action menu seam + Example wiring (macOS + iOS) + 0.6.0 release.

## OQ resolutions (review round, 2026-07-04 — all unanimous)

- **OQ-A ✅ one state-dependent toggle** (+ the apply-wins mixed-state rule above).
- **OQ-B ✅ two-state enum** (identity-boxed per the coalescing Major); rotate deferred.
- **OQ-C ✅ no cap** — WYSIWYG is the feedback; a cap encodes JIS taste into a tool
  whose users deliberately break type rules. Ugly-long-run tests fail safely.
- **OQ-D ✅ available-and-inert in horizontal** — intent survives orientation flips
  (alignment/pitch precedent); a hidden item would make the attribute a phantom state.
  Menu help text: "applies in vertical text".

## PR-1+PR-2 review fold (2026-07-04, three reviewers)

All findings folded on develop; 248/248 green.

- **Parser fail-safe hardened (blocker ×2)** — the old recovery (re-emit `[[`,
  rescan from start+2) let a valid inner command annotate from inside a
  malformed one. Now ANY invalid command re-emits its ENTIRE raw region —
  opener through the first unescaped `]]`, or end of input — with zero
  annotations. A malformed opener may swallow a later valid command into
  literal text: the safe direction. A second bare `|` in ruby is malformed
  (escape to include).
- **Serialize emits non-ruby fragments (blocker)** — a TCY override straddling
  a ruby base encodes its surviving `combine − ruby` fragments (the exact
  algebra `effectiveGroups` renders) instead of whole-span drop; wholly-covered
  emits nothing. `PorticoTateChuYoko.subtract` went internal so the encoder
  and the layout share one subtraction.
- **Surgery symmetry** — `PorticoRuby.setRuby` now removes the override under
  the new base (fragments outside survive), mirroring `setTateChuYoko`'s
  clearing in the other direction. The combine→setRuby-over-it state that
  broke round-trip identity is no longer constructible through surgery;
  direct-attribute states round-trip to their canonical equivalent.
- **Typing strictly inside an override extends it** — ruby parity settled by
  reading the house rule (`insertionExtendsRubyGroup`): interior insertions
  join the span (same box instance, one run); boundary insertions stay plain.
  Applies to insertText, marked text, and paste (paste never inherits).
- **Sweep hardened** — alphabet gains newline + non-BMP surrogate pairs
  (𩸽 🙂); override ranges are built on character boundaries.
- **Interior-tap equivalence recorded** — for 2-char groups the mini-line-gap
  rule and the v1 nearer-boundary snap are identical, so device-witnessed W2
  behavior is preserved; the rewrite only adds interior gaps for 3+ groups.
- **Aozora live conversion posture** — `applyInlineRubyConversion` (typing
  `《》`) is a deliberate one-way IMPORT at typing time, same quarantine class
  as `parse(aozora:)`; documented at the site. Nothing serializes to `《》`.

Rides PR-3 (recorded): switch `serializedSelection`/`insertNotation` from the
Aozora path to `PorticoNotation` (closes the paste-adjacent same-box
coalescing hazard by construction — parse mints a fresh box per command), and
add the direct pin: copy a combined span, paste adjacent, expect two distinct
cells.

## PR-3 record (2026-07-04)

Built per the locked scope + the fold-round rulings:

- **Menu seam → provider** — `PorticoSelectionMenuProvider = (NSRange) ->
  [PorticoSelectionMenuAction]`, evaluated at menu-open (macOS context menu items
  carry their index in `representedObject`; a bare responder-chain send invokes the
  FIRST action — Ruby… in the Example; iOS maps actions into the edit menu inline
  group). Single-action `onSelectionMenuAction:` inits wrap into a one-element
  provider.
- **Engine toggle API** — `tateChuYokoToggle(for:)` (`.apply`/`.release`; release
  iff the whole range already renders 縦中横; mixed = APPLY-WINS) and
  `performTateChuYokoToggle(for:)` (apply = one combine span, surgery removes
  suppress; release = clear explicit overrides, then SUPPRESS auto groups still
  intersecting — full atomic ranges, one undo step; a cleared pure combine stores no
  unnecessary suppress).
- **Clipboard → owned notation** — `serializedSelection`/`insertNotation` switched
  from Aozora to `PorticoNotation`; paste-adjacent-distinct-cells pinned (fresh box
  per parsed command closes the coalescing hazard by construction).
- **Aozora posture (owner ruling)** — live `《》` typing conversion is now behind
  `importsAozoraRubyWhileTyping`, DEFAULT OFF; the PASTE boundary imports Aozora
  regardless (`PorticoRuby.importAozora(in:)` layered after the owned-grammar
  parse). The Example opts into typing conversion; MangaLoft opts in until it grows
  a ruby menu. Known misfire while enabled (and on paste): `《》` is legitimate
  title punctuation (《吾輩は猫である》), so kanji + title can convert to surprise
  ruby — undo reverses in one step; if an operator complains, the pre-made fix is a
  host preference, not removal.
- **Example** — both menu entries on both platforms; demo text gained a TCY line
  (平成12年3月10日、第158刷。まさか!?); ⇧⌘T main-menu toggle (macOS) reads its
  title from the bridged engine at menu-open.
