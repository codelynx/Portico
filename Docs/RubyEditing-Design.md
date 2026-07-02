# Ruby (Furigana) Editing — Design (Phase 3)

> **Status:** **implemented (Phase 3 complete)** — see §10 for per-step status. Consolidates
> the maintainer's and three review agents' input. Method signatures here are the *interface
> contract*; this doc remains the spec of record for the editing model.

## 1. Purpose & framing

Make ruby *editable* in Portico. Portico is a **framework module** — it does **not**
own the editing UI; clients do (novel writers, manga speech-bubble tools, …). So the
framework's job is **UI-agnostic primitives + editing semantics + geometry**, rich
enough that any client interaction pattern is buildable on the public API.

Starting point (pre-Phase-3): `parse` / `serialize` / render existed, but there was **no**
interactive add/edit/remove and no ruby-aware editing. Two concrete defects were fixed here:
insertion **inherited** the `CTRubyAnnotation` from the preceding char (typing after a base
extended the group), and delete was char-level with no range maintenance. Both are resolved —
see §10 for per-step status.

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
  Contract: converts **only on committed text — never inside IME marked text**. Designed to
  be **undoable in one step** back to the literal characters (escape hatch for a literal `》`)
  — the reversion is a single text replacement, but no undo manager is wired to the engine
  yet, so this is a design property, not a shipped feature (§11, still open).
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

### 7.2 Unified authoring UX (post-0.1.0 refinement — supersedes §7.1's pointing path)

The shipped 0.1.0 Example forked the editor by selection state — popover when the selection
was inside a ruby group, bottom bar otherwise. That split was an **artifact**, not a design:
`rubyAnchorRectForSelection()` only produced a rect inside a group, so plain selections had no
anchor and fell back to a different surface. Two affordances for one action ("set the reading
for this selection"), chosen by state the user can't see — and on iOS the auto-editor competed
with the native selection menu that `UITextInteraction` now shows. Consolidated design (three
review agents + coordinator):

**One flow — select any text → native edit action → one prefilled popover anchored to the
selection.** Inline notation (§7a) stays the *primary, fast* bulk-authoring path; this is the
deliberate **touch-up** path, so the one extra tap is appropriate.

- **Trigger — native menu, per platform:**
  - **iOS:** contribute the item through `UITextInput.editMenu(for:suggestedActions:)`
    (`suggestedActions + [client action]`) — the point UIKit already calls with the selection
    menu up. **Do not** install a second `UIEditMenuInteraction`; it would collide with the one
    `UITextInteraction` owns (the double-menu / gesture-fight class we removed with the custom
    recognizers).
  - **macOS:** a right-click context-menu item **plus** an `Edit ▸ Ruby…` command (the command
    carries a keyboard shortcut — discoverability + keyboard-first in one control).
- **Framework owns plumbing, not UI.** Portico exposes a **selection-menu seam**: the client
  supplies the action (title + handler); the framework wires it into the native menu on both
  platforms and hands back the **selection range + anchor rect**. Opt-out by default — no hook,
  no ruby menu item. The `Ruby…` label and the popover itself stay **client-owned** (Example).
  Keeps §2's framework-first principle: Portico never mandates editing UI.
- **One surface, three ops by prefill:**
  - Selection **exactly equals** one group's base → **edit** (field prefilled).
  - Otherwise (plain / partial-inside-group / spanning groups) → **add or replace over the
    selection** (empty field); apply calls `setRuby` over the selection under its existing
    replace-on-intersect contract (§5). A partially-selected group is never silently *edited* —
    the field opens empty (the signal), and applying deliberately replaces the intersected group
    under §5's contract. Tap-to-edit already snaps to the full group (containment hit-test), so
    the common edit case lands on exact-match.
  - **Remove:** clear the field and apply. One control (Apply) covers set / edit / remove; the
    field *is* the state. (The review round argued for an additional explicit Remove button so
    destruction is visible; the maintainer preferred the single clear-and-apply affordance — a
    deliberate taste call, with the checkmark's tooltip noting that a cleared field removes.)
- **Anchor geometry — `anchorRectForSelection()` (new engine helper).** This is a **popover-anchor
  contract, not a selection-bounds contract**: it returns the rect of the selection's **first
  segment in document/layout order** (its run on the first line horizontally; the first column
  in vertical RTL order — "first" meaning document order, not visual left), flipped to top-left.
  *Not* the union (huge & arbitrary in vertical/wrapped, anchors into whitespace) and *not* the
  active end — active-end anchoring makes the same selection anchor differently by drag
  direction, and is **undefined for two of this menu's own entry points** (double-click
  word-select and macOS right-click have no meaningful active end). The existing ruby-group
  `rubyAnchorRectForSelection` is **regularized to the same first-segment policy**, which also
  fixes its documented coarse-union weakness. One anchor contract for both the ruby and plain
  cases. A general `selectionBoundingRect` (union) can be added later if a client needs it — kept
  separate so "anchor" never means "bounds."
  - **Revisit trigger (locked-with-exit):** if the sim/manual pass shows the popover feeling
    disconnected from the gesture on a long multi-column vertical selection, flip to active-end
    (or last-segment) — a one-line contract change. The empirical counter-argument gets a defined
    exit rather than blocking the decision now.

**Scope:** Example UX + one engine geometry helper + one small view seam. **No new framework
semantics** — `setRuby`, `rubyGroup(at:)`, and `selectionRects(for:)` already back the flow;
that the API survived a full UX rethink needing only geometry/seam plumbing is itself the
client-agnostic validation §7.1 set out to prove.

**Verification note:** the iOS menu-item pass needs an on-device/simulator check that the
custom item actually appears alongside Copy / Look Up with the native selection UI up — the one
integration in this design with real unknowns.

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

## 10. Implementation status (order was simple-first)

**Phase 3 complete** — all six steps implemented, tested, and pushed. Review follow-ups noted inline.

1. ✅ **Insertion/inheritance boundary rule** (§6) — incl. IME marked text.
2. ✅ **Primitives** — `setRuby` + `rubyGroup(at:)` / `rubyGroups(in:)` (pure, tested).
3. ✅ **Post-edit integrity** (§6) — the attribute store already preserves the invariant; no
   normalization pass, locked by round-trip tests.
4. ✅ **Geometry primitives** — `rubyGroup(at point:)` (**containment** hit-testing — follow-up
   fix so a tap on a one-kanji base's trailing half still hits), `rects(forRubyGroupContaining:)`,
   `anchorRect(forRubyGroupContaining:)`.
5. ✅ **Inline notation conversion** (§7a) — auto-base stops at an existing group; explicit `｜`
   crosses it (follow-up fix, so a new inline ruby can't swallow a neighbour).
6. ✅ **Example demo** — select → reading editor; on iOS/macOS the editor anchors to the group
   via `anchorRect`. This is the §5/§7.1 **acceptance test — executed and passed** (vertical
   included), which is how we know the geometry API is genuinely client-buildable.

Adjacent non-ruby fixes done in the same phase: grapheme-aware `deleteBackward`, iOS selection
UI refresh on programmatic text change / orientation flip, macOS double-click word-select.

## 11. Open questions

Resolved during implementation:
- **Where does `setRuby` live?** — **Both**, as anticipated: pure ops on `PorticoRuby`
  (`setRuby` / queries / `inlineRubyMatch`) plus engine-level geometry (`anchorRect…`) and the
  inline-conversion hook. No separate normalization pass was needed (§3, §10 step 3).
- Trimming (store as-given) and the zero-length-range no-op — decided (§5).

Genuinely still open:
- **Undo granularity** for inline conversion and `setRuby` — one step or per-char? (No undo
  manager is wired to the engine yet.)
- **Reading normalization** on input (full-width/half-width kana) — framework or client?

## 12. Parked ideas (future, not v1)

- **IME-reading capture** (Ichitaro-style ふりがな自動振り): at composition-commit the client
  transiently knows the kana typed before conversion; offer "use what you just typed as the
  ruby." Falls out nearly free *if* the framework later exposes a composition-commit hook —
  a genuine differentiator.
- **Escaping / literal-marker support** for base text containing literal `《`, `》`, or `｜`
  — would extend the §9 round-trip guarantee to those states (RubySupport.md §3.1/§4).
- In-flow reading editor (§7c), split/merge, per-mora alignment.
