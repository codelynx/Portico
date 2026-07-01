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
  reading attaches nothing), so `nil` and `""` behave alike.
- **Address groups by character index, not ordinal** (ordinals go stale on edit; a caret
  or tap already gives you an index):
  ```
  rubyGroup(at index: Int) -> (base: NSRange, reading: String)?
  rubyGroups(in range: NSRange) -> [(base: NSRange, reading: String)]
  ```
  All `NSRange` are **UTF-16, half-open Foundation ranges**. `rubyGroup(at:)` returns a group
  only for an index **strictly inside** the base (not at the end boundary).
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
  **Acceptance test for the API's completeness:** "could the deferred inline/popover
  vertical editor (§7b) be built purely on the public API?" With these primitives, yes.

Shape mirrors the existing pure `PorticoRuby.parse`/`serialize` (attributed-string in/out,
unit-testable), rather than a new stateful subsystem.

## 6. Editing semantics (Q3) — editable base, atomic reading

- **Caret model = hybrid.** The base is **real text**: the caret steps through it
  char-by-char and it stays editable (atomic groups would stop you fixing a typo inside a
  base without destroying its ruby — that surprises, and fights IME/selection). The
  **reading is an attribute** — never caret-reachable, edited only as a whole via §5/§7.
- **Insertion rule (precise, generalizes the bug fix):** an insertion strictly **inside**
  a base extends the group; an insertion at **either boundary** is **plain text**. This is
  the standard attribute-edge rule; the adjacent-typing bug is the boundary case of it.
- **Delete = per-char; group shrinks; an empty group disappears.** Backspace inside a base
  shrinks the annotation range; deleting the last base char drops the group. A shrunk group
  is a **valid state** (range maintenance), not the old "half-annotated base" bug. A reading
  can go semantically stale after base edits — that's the author's problem, as in Word; the
  framework does not try to be clever.
- **Partial-base selection: allowed, no snapping.** Selection is plain text selection.
  Expose a group-boundary query so clients can implement snap-on-double-tap *themselves* if
  they want it — Portico doesn't force it.
- **Post-edit normalization.** Because `NSMutableAttributedString` edits can split/truncate
  the annotation range, the engine runs a normalization pass after edits: coalesce/re-anchor
  ruby to its surviving contiguous base and drop empties, preserving the §3 invariant.

## 7. Authoring UX (Q2) — two supported paths, one deferred

*(Coordinator note: I initially argued against inline notation over nested-IME concerns.
The reviewers changed my mind — Japanese novelists already author with inline `《》` markup
on the dominant platforms (narou, kakuyomu) and vertical editors (TATEditor, 縦式), and the
IME concern dissolves with a "committed text only" trigger.)*

- **(primary, keyboard-first) Inline notation conversion.** Type `漢字《かんじ》` (and the
  `｜` explicit-base form the parser already supports) and it converts on the closing `》`.
  Contract: converts **only on committed text — never inside IME marked text**; cleanly
  **undoable** back to the literal characters (escape hatch for a literal `》`).
- **(reference API validation) Select base → set/edit reading.** Selection → query →
  `setRuby`. This is the MS Word ルビ-dialog idiom; ship it as the **Example app's** demo
  (a small popover/field), proving the primitives against a real workflow.
- **(deferred) Inline / vertical direct entry.** The most delightful, the hardest. Deferred;
  used as the §5 completeness acceptance test rather than built now.

## 8. Display

When a base is selected, **highlight its reading too** — a group reads as one unit even
though it edits as text. (Consciously decided; previously undefined.)

## 9. Correctness / acceptance criteria

- **Round-trip after every edit:** post-edit, the buffer must `serialize` to valid notation
  and `parse` back to the **same text + ruby-group semantics** (base ranges + readings — not
  every attributed-string styling attribute byte-for-byte). Extending the existing
  parse/serialize idempotence tests over **post-edit states** is the cheapest correctness net
  and forces §6 to be self-consistent.
- **Invariant (§3) holds** after every mutation and normalization.
- **Boundary/inheritance rule (§6)** covered by tests.

## 10. Suggested implementation order (simple-first)

1. **Fix the insertion/inheritance boundary rule** (§6) — isolated, correct regardless.
2. **Primitives** — `setRuby` + `rubyGroup(at:)` / `rubyGroups(in:)` + tests (pure, no UI).
3. **Post-edit normalization pass** (§6) — the real engine work; the round-trip tests gate it.
4. **Geometry primitives** — `rubyGroup(at point:)`, `rect(forRubyGroupAt:)`.
5. **Inline notation conversion** (§7 primary) with the committed-text/undo contract.
6. **Example demo** — select → popover reading field (§7 reference).

## 11. Open questions (for further discussion)

- **Where does `setRuby` live?** §5's shape mirrors the pure `parse`/`serialize`, but
  interactive editing also needs an **engine-level** mutator that runs §6 normalization,
  relayout, and `textDidChange`. Likely **both** — a pure core transform plus a thin engine
  wrapper — but decide consciously, not by accident during implementation.
- Undo granularity for inline conversion and `setRuby` — one step or per-char?
- Should `setRuby` on a **zero-length** (caret-only) range be a no-op, or place an empty
  base marker? (Lean: no-op.)
- Reading normalization on input (full-width/half-width kana, trimming) — framework or client?

## 12. Parked ideas (future, not v1)

- **IME-reading capture** (Ichitaro-style ふりがな自動振り): at composition-commit the client
  transiently knows the kana typed before conversion; offer "use what you just typed as the
  ruby." Falls out nearly free *if* the framework later exposes a composition-commit hook —
  a genuine differentiator.
- Vertical direct reading entry (§7b), split/merge, per-mora alignment.
