# Undo / Redo — Design

> **Status:** **designed, not built.** Consolidates the maintainer's framing and three review
> agents' input. Method names here are the *interface contract*, not final signatures. Resolves
> the undo item deferred in `RubyEditing-Design.md` §11.

## Purpose & framing

Add Undo/Redo — the last editing gap. Portico is **framework-first** (owns primitives + geometry,
not the app's editing UI), a platform-neutral **engine** + thin per-platform **view**, and today
has **two mutation channels**: engine-native edits (`insertText` / `deleteBackward` /
`insertNotation`, IME commit) and **client binding edits** (the ruby editor replaces the `text`
binding, arriving as `update(attributedString:)`). Undo must cover both coherently.

## 1. Ownership & lifecycle — undo is model-scoped

**`PorticoTextLayoutEngine` owns the undo lifecycle and holds an `UndoManager`.** `UndoManager`
is **Foundation** (not AppKit/UIKit), so the platform-neutral engine can own one and register its
own operations. The per-platform view **vends** it by overriding `var undoManager: UndoManager?`
(present on `NSView` and `UIResponder`), so Edit ▸ Undo/Redo, ⌘Z / ⇧⌘Z, and iOS shake resolve to
the engine's stack automatically through the responder chain.

- **Injected-or-defaulted.** The engine owns the *lifecycle*; the manager itself defaults to a
  private instance but is **injectable** — a document-style app hands Portico its document's
  `UndoManager` so edits compose with the app's undo ecosystem. (This is also the headless test
  seam.) The default gives a reusable component sane isolation; injection gives host composition.
- **Independent per engine** — two components = two engines = two stacks; no interleaving.
- **Lifecycle follows the model** — while the client retains the engine, undo history survives
  view teardown (navigation, cell reuse, tab switch); re-attaching a fresh view keeps it. Engine
  deallocates ⇒ stack goes with it. On deinit the engine removes its own actions from the manager
  (`removeAllActions(withTarget:)`) so an *injected* manager that outlives it is never left with
  dangling actions.
- **`@MainActor` engine.** Because `UndoManager` is main-actor-isolated in the SDK, the engine is
  `@MainActor` (it's main-thread UI state anyway — the views are already main-actor). Consequence:
  **background/offscreen layout on a non-main queue isn't supported.**
- **Injected `groupsByEvent`.** The default manager uses `groupsByEvent = false` and explicit
  per-step groups. An injected manager keeps *its* setting; a `groupsByEvent = true` manager
  (e.g. `NSDocument`'s default) nests our per-step groups inside its per-run-loop event group, so
  several programmatic edits in one cycle coalesce into one undo. That's expected, matches
  `NSTextView`'s document behavior, and is left as-is (forcing `false` would reject the most
  natural host managers).

**API implication — engine injection.** `PorticoView(text:)` creates the engine internally, tying
undo to the view. Model-scoped undo requires the client to own the engine:

```
PorticoView(engine: retainedEngine)        // client owns model + undo (survives recycling)
PorticoView(text: $binding, …)             // convenience; engine internal → undo is view-scoped
```

- **Orientation single source of truth:** orientation is **engine state**. The `engine:` API does
  **not** take an orientation parameter (that would duplicate `engine.orientation`); it drives the
  engine's orientation (e.g. via a binding that writes through). The `text:` sugar keeps its
  `orientation:` param and forwards it to the internal engine.
- **Observation seam:** the `engine:` path has no `text` binding, so text/selection changes for
  dirty-tracking, save state, and view refresh flow through the engine's existing
  `textDidChange` / `selectionDidChange` callbacks. Document these as the observation contract.

*(This refines an earlier "use the responder chain's `UndoManager`, never create one" suggestion:
that manager is window-scoped — shared across unrelated components and lost on teardown — wrong for
a reusable model component. Engine-owned + injectable is the `NSDocument`-style answer and keeps
the host-composition benefit.)*

## 2. Registration — engine registers; no retain cycle

The engine both performs the mutation and registers the inverse with its `UndoManager`; the view
only vends the manager (no AppKit/UIKit in the engine).

**Retain-cycle contract (must-fix, not implementation trivia):** register with **target-based**
registration where the `UndoManager` holds the engine **unowned** — never a closure that captures
the engine strongly, which would form `engine → manager → handler → engine`. The inverse operation
recomputes from the target (engine) at invocation time.

## 3. State model — snapshot per step, bounded

A step captures and restores `(attributedString, cursorIndex, selectionRange)`; marked range is
cleared (composition never restored); orientation is not part of a step (edits don't change it).
Undo restores the prior snapshot; redo re-applies. Ruby is handled trivially — it's just the
attributed string.

- **Bounded memory:** set a default `levelsOfUndo` cap (~100, publicly tunable). `UndoManager`
  defaults to *unlimited*, which with full-string snapshots grows without bound over a long
  session; a cap makes the ceiling boring and defers delta-encoding honestly.
- **Escape hatch (not v1):** delta-encoding (range + old/new substring) if profiling ever demands.

## 4. Granularity & coalescing

- **Plain committed typing** coalesces into one run. With snapshots this is nearly free: register
  the pre-run snapshot **once** at run start, register nothing for subsequent keystrokes. **Break
  the run** on: caret move / selection change, any non-insert op, an undo/redo, an **insertion
  attribute-context change** (e.g. typing inside a ruby base vs. immediately after it), and the IME
  commit boundary. **No pause-timer** in v1 (adds state + test flakiness for marginal gain).
- **Structural ops** — paste, cut, delete-selection, `setRuby`, inline `《》` conversion — are each
  one discrete step; no coalescing.
- **Inline-conversion ordering:** the open typing run must be **closed before** the structural
  conversion step registers, so undo returns to the literal `漢字《かんじ》` in one step (not undoing
  the whole typed notation). This **closes the §11 open question** — the promised escape hatch.

## 5. Binding channel & document reset

- **Undoable user edits go through engine editing commands** (`insertText`, `deleteBackward`,
  `insertNotation`, engine-level `setRuby`), which register undo. With engine injection (§1), the
  ruby editor calls `engine.setRuby(…)` instead of replacing the binding → the headline flow is
  first-class undoable.
- **A genuinely-external, content-differing replacement is a document reset** → it **clears the
  Portico-registered undo actions only**: `removeAllActions(withTarget: engine)`, **never**
  `removeAllActions()` (which would nuke a host-injected manager's own history). Engine-originated
  binding echoes (the `textDidChange` round-trip) are **not** resets — the existing `!= text` guard
  distinguishes them. Document load/sync clears; typing round-trips don't.

## 6. IME

No undo steps while marked text exists; register only on commit. Enablement is a **view-layer**
responsibility too: the view validates Edit ▸ Undo/Redo (and equivalents) as **disabled while
`markedRange != nil`**, so the no-op isn't mysterious. The system IME keeps its own preedit
cancel/undo behavior.

## 7. Scope (v1)

Full editing surface — typing, delete, paste, cut, `setRuby`, inline conversion. Partial coverage
is worse than none: users can't predict which edits are safe.

## 8. Acceptance criteria

- Every user-visible edit path (typing, delete, paste, cut, select→Ruby, inline `《》` conversion)
  undoes to the previous `(attributedString, caret/selection)` in **one coherent step**, and redoes.
- Two views backed by **different engines** have independent undo; edits don't cross stacks.
- Undo history **survives view teardown** when the client retains the engine; **lost** when it
  deallocates.
- Injected host manager: a document reset clears only Portico's actions, not the host's.
- No retain cycle: dropping all references to the engine deallocates it (and its manager).
- ⌘Z / Edit ▸ Undo (macOS) and ⌘Z / shake (iOS) drive it; disabled during IME composition.
- Headless test: inject a bare `UndoManager`, apply each edit type, assert undo/redo restores text
  + selection, and that `levelsOfUndo` bounds the stack.

## 9. Open questions (what genuinely remains)

1. Exact shape of the `engine:` API and how orientation is threaded (binding vs. direct).
2. Coalescing break-set completeness (is the attribute-context break sufficient, no timer?).
3. Snapshot ceiling: is a `levelsOfUndo` default enough for v1, or design the delta hook now?
4. On-device: vending a custom `undoManager` on iOS alongside `UITextInteraction` — verify the
   shake sheet shows *our* Undo and nothing double-registers during autocorrect/IME.

## 10. Docs to update when this lands

`RubyEditing-Design.md` §11 (resolve undo granularity), README deferred list (remove Undo/Redo),
`PlatformParity.md` (undo row), `CHANGELOG.md`.
