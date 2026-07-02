# Ruby (Furigana) Editing — Design (Phase 3)

> **Status:** design draft, not yet implemented. Consolidates the maintainer's and
> three review agents' input. Focus is **what**, not how. Method signatures here are
> the *interface contract* (a framework's public surface is part of its "what"), not
> implementation.

## 1. Purpose & framing

Make ruby *editable* in Portico. Portico is a **framework module** — it does **not**
own the editing UI; clients do (novel writers, manga speech-bubble tools, …). So the
framework's job is **UI-agnostic primitives + editing semantics + geometry**, rich
enough that any client interaction pattern is buildable on the public API.

Today: `parse` / `serialize` / render exist; there is **no** interactive add/edit/remove
and no ruby-aware editing. Two concrete defects to fix: insertion **inherits** the
`CTRubyAnnotation` from the preceding char (typing after a base extends the group), and
delete is char-level with no range maintenance.

## 2. Principles

- **Framework-first** — expose primitives; mandate no UI.
- **Simple first, no frills.**
- **Explicit groups** — ruby is applied to an explicitly selected base; **never**
  auto-detected during editing.
- **Cross-platform** (macOS + iOS), **horizontal and vertical**.

## 3. Core data model (invariant)

A ruby group is **one contiguous base range + one reading string**, stored as a single
`CTRubyAnnotation` over the whole base. No hidden side table, no per-character mapping.
This invariant must hold before and after every edit.

## 4. Non-goals (v1)

Explicitly out of scope (record, don't decide silently):
- Jukujikun / **per-mora alignment** (Aozora notation can't express it; the serializer
  would lose it anyway).
- **Automatic kanji detection** during editing.
- **Split / merge** of groups as first-class ops (a client composes them from set/remove).
- Multiple alternate readings per base.
- Any **Portico-mandated ruby UI**.
- **Vertical direct reading entry** — deferred (see §7), not rejected.

## 5. API surface (Q1)

Resolved shape (agents converged; the collapse and index-addressing were review picks):

- **One mutator, not three verbs** — add/edit/remove are the same operation:
  ```
  setRuby(_ reading: String?, for baseRange: NSRange)   // nil — or empty/whitespace — removes
  ```
  An **empty or whitespace reading removes** the group (matching `parse`, where an empty
  reading attaches nothing), so `nil` and `""` behave alike. A **zero-length or out-of-bounds
  `baseRange` is a no-op**, and a non-blank reading is stored **as given** (trimming only
  decides removal; kana normalization is the client's call).
- **Address groups by character index, not ordinal** (ordinals go stale on edit; a caret
  or tap already gives you an index):
  ```
  rubyGroup(at index: Int) -> (base: NSRange, reading: String)?
  rubyGroups(in range: NSRange) -> [(base: NSRange, reading: String)]
  ```
  All `NSRange` are **UTF-16, half-open Foundation ranges**. `rubyGroup(at:)` returns a group
  only for an index **strictly inside** the base (not at the end boundary) — so the junction
  index between two adjacent groups belongs to the *following* group. Clients wanting a
  "nearest group" (e.g. a caret just past the last kanji) handle that boundary themselves.
- **Overlap rule (define now):** `setRuby` over a range intersecting existing groups
  **replaces** them — attribute-set semantics: destructive, predictable. Precisely: remove
  the **full ranges** of all intersecting ruby groups, then apply the new reading to
  `baseRange`; **no leftover split fragments** in v1.
- **Editing sanitizer** — the inheritance bug is really a missing rule: attributes copied
  into inserted text must be sanitized so ruby doesn't leak across boundaries (see §6).
- **Geometry primitives (required for client-agnosticism):** clients building tap/popover
  editing need these, and only the layout engine can answer them. Named by *containing
  index* (not ordinal), and returning **engine layout / Core Text coordinates** — platform
  view wrappers flip to view coordinates, matching `caretRect` / `firstRect`:
  ```
  rubyGroup(at point: CGPoint) -> (base, reading)?        // point in layout coords; incl. taps on the reading
  rects(forRubyGroupContaining index: Int) -> [CGRect]    // plural — a group can wrap across lines/columns
  anchorRect(forRubyGroupContaining index: Int) -> CGRect // one rect for popover placement
  ```
  **Acceptance test for the API's completeness:** "could the deferred in-flow reading editor
  (§7c) be built purely on the public API?" With these primitives, yes.

Shape mirrors the existing pure `PorticoRuby.parse`/`serialize` (attributed-string in/out,
unit-testable), rather than a new stateful subsystem.

## 6. Editing semantics (Q3) — editable base, atomic reading

- **Caret model = hybrid.** The base is **real text**: the caret steps through it
  char-by-char and it stays editable (atomic groups would stop you fixing a typo inside a
  base without destroying its ruby — that surprises, and fights IME/selection). The
  **reading is an attribute** — never caret-reachable, edited only as a whole via §5/§7.
- **Insertion rule (precise, generalizes the bug fix):** an insertion strictly **inside** a
  base extends the group; an insertion at **either boundary** is **plain text** — for both
  typed and IME-composing (marked) text. This is the standard attribute-edge rule; the
  adjacent-typing bug is the boundary case of it.
- **Delete = per-char; group shrinks; an empty group disappears.** Backspace inside a base
  shrinks the annotation range; deleting the last base char drops the group. A shrunk group
  is a **valid state** (range maintenance), not the old "half-annotated base" bug. A reading
  can go semantically stale after base edits — that's the author's problem, as in Word; the
  framework does not try to be clever.
- **Partial-base selection: allowed, no snapping.** Selection is plain text selection.
  Expose a group-boundary query so clients can implement snap-on-double-tap *themselves* if
  they want it — Portico doesn't force it.
- **Post-edit integrity — the attribute store handles it (verified on current platforms).** We
  expected to need a normalization pass, but `NSMutableAttributedString` already does the right
  thing: it re-anchors a group's `CTRubyAnnotation` to its surviving contiguous base on delete,
  extends it on an interior insert, and drops it when the base is emptied. And because each group
  is a **distinct** annotation object, adjacent groups (even same-reading) don't coalesce. This is
  undocumented framework behavior, not an API guarantee — so rather than add a normalization pass,
  the edit-scenario **round-trip tests** (delete inside / whole / across-boundary, adjacent incl.
  same-reading, interior insert, replace-over-multi-group, newline-merge) are the guard that would
  catch any OS regression. A reading can still go semantically stale after a base edit — the
  author's problem, not a structural break.
- **`deleteBackward` deletes whole grapheme clusters** (via `rangeOfComposedCharacterSequence`),
  so a base containing a surrogate-pair CJK-extension character, emoji, or combining sequence
  deletes as one unit rather than splitting into an invalid string. (Previously a single-UTF-16-unit
  deletion; fixed as its own small non-ruby engine packet.)

## 7. Authoring UX (Q2) — two supported paths, one deferred

*(Coordinator note: I initially argued against inline notation over nested-IME concerns.
The reviewers changed my mind — Japanese novelists already author with inline `《》` markup
on the dominant platforms (narou, kakuyomu) and vertical editors (TATEditor, 縦式), and the
IME concern dissolves with a "committed text only" trigger.)*

- **(a) Inline notation conversion** — *primary, keyboard-first.* Type `漢字《かんじ》` (and the
  `｜` explicit-base form the parser already supports) and it converts on the closing `》`.
  Contract: converts **only on committed text — never inside IME marked text**; cleanly
  **undoable** back to the literal characters (escape hatch for a literal `》`).
- **(b) Select base → set/edit reading** — *reference API validation.* Selection → query →
  `setRuby`; the MS Word ルビ-dialog idiom. Ship it as the **Example app's** demo — see §7.1
  for the per-platform form.
- **(c) In-flow reading editor** — *deferred.* Editing the reading in place on the base — the
  most delightful, the hardest (especially vertical). Deferred; used as the §5 completeness
  acceptance test rather than built now.

### 7.1 UX recommendation per platform

The framework supports all patterns (each reduces to *current-group query* + `setRuby` +
optional geometry). What follows is the recommended **primary path** and **Example
reference**, not a mandate on clients.

| Pattern | In-flow feel | Discoverable | Bulk edit | Screen cost | Vertical | API needed |
|---|---|---|---|---|---|---|
| **Inspector** (persistent field) | ✗ eyes leave text | ✅✅ | ✅✅ | high | ✅ (separate UI) | current-group + `setRuby` |
| **Popover** (anchored on base) | ~ near text | ✅ | ~ open/close friction | low | ⚠️ arrow placement | + `anchorRect(…)` |
| **Direct / inline notation** (`《かんじ》`) | ✅✅ fully | ✗ must know markup | ✅ fluent authors | none | parser + insert hook |

*(A floating **in-flow reading editor** on the base is the deferred §7 "direct entry" — the
most delightful and the hardest, especially vertical.)*

**Recommendation:**
- **Primary = direct / inline notation.** Keyboard-first, zero UI, identical horizontal/
  vertical, all platforms; matches how novelists already write. The power path.
- **Reference (pointing) = platform-idiomatic:**
  - **macOS → inspector** — discoverable, good for bulk furigana passes, needs *no* geometry,
    and is the MS Word ルビ-dialog muscle memory. Cheapest to demo.
  - **iOS → popover** anchored to the tapped group — the touch idiom, and it **exercises the
    `anchorRect` geometry primitive**, which is the acceptance test that the API is truly
    client-agnostic.
- **Defer the in-flow reading editor** (esp. vertical) — but `rects(…)` leaves the door open.

**Why this split:** fluent authors get the fast keyboard path everywhere; discoverability
comes from the native pointing idiom per platform; and the iOS popover *forces* the geometry
primitives to be proven — the whole API's completeness check.

## 8. Display

When a selection **intersects** a ruby base, **highlight its reading too**, always as a
**whole** (a partially-highlighted reading would imply per-mora mapping — a non-goal). A
group reads as one unit even though it edits as text. (Consciously decided; previously
undefined.)

## 9. Correctness / acceptance criteria

- **Round-trip after every edit — for serializable states.** If the base text and readings
  contain **no literal Aozora control characters** (`《`, `》`, `｜`), the buffer must
  `serialize` to valid notation and `parse` back to the **same text + ruby-group semantics**
  (base ranges + readings — not every attributed-string styling attribute byte-for-byte).
  States containing literal control characters remain valid in memory but are **outside v1's
  round-trip guarantee** until escaping exists (see RubySupport.md §3.1/§4 and §12 below).
  Extending the existing parse/serialize idempotence tests over **post-edit states** is the
  cheapest correctness net and forces §6 to be self-consistent.
- **Invariant (§3) holds** after every mutation and normalization.
- **Boundary/inheritance rule (§6)** covered by tests.

## 10. Suggested implementation order (simple-first)

1. **Fix the insertion/inheritance boundary rule** (§6) — isolated, correct regardless.
2. **Primitives** — `setRuby` + `rubyGroup(at:)` / `rubyGroups(in:)` + tests (pure, no UI).
3. **Post-edit integrity** (§6) — turned out the attribute store already preserves the
   invariant under edits, so no explicit normalization pass is needed; locked by round-trip tests.
4. **Geometry primitives** — `rubyGroup(at point:)`, `rects(forRubyGroupContaining:)`,
   `anchorRect(forRubyGroupContaining:)`.
5. **Inline notation conversion** (§7a) with the committed-text/undo contract.
6. **Example demo** — select → reading, per §7.1 (inspector on macOS, popover on iOS).

## 11. Open questions (for further discussion)

- **Where does `setRuby` live?** §5's shape mirrors the pure `parse`/`serialize`, but
  interactive editing also needs an **engine-level** mutator that runs §6 normalization,
  relayout, and `textDidChange`. Likely **both** — a pure core transform plus a thin engine
  wrapper — but decide consciously, not by accident during implementation.
- Undo granularity for inline conversion and `setRuby` — one step or per-char?
- Reading normalization on input (full-width/half-width kana) — framework or client? *(Trimming
  and the zero-length-range no-op are now decided — see §5.)*

## 12. Parked ideas (future, not v1)

- **IME-reading capture** (Ichitaro-style ふりがな自動振り): at composition-commit the client
  transiently knows the kana typed before conversion; offer "use what you just typed as the
  ruby." Falls out nearly free *if* the framework later exposes a composition-commit hook —
  a genuine differentiator.
- **Escaping / literal-marker support** for base text containing literal `《`, `》`, or `｜`
  — would extend the §9 round-trip guarantee to those states (RubySupport.md §3.1/§4).
- In-flow reading editor (§7c), split/merge, per-mora alignment.
