# iOS ↔ macOS Platform Parity

Portico's layout **engine** (`PorticoTextLayoutEngine`) is platform-neutral pure
Core Text and behaves identically on both platforms. All parity differences live in
the **view layer** (`PorticoTextView`), where macOS uses `NSView`/`NSTextInputClient`
and iOS uses `UIView`/`UITextInput` + `UITextInteraction`.

## 1. Status

| Capability | macOS | iOS | Notes |
|---|---|---|---|
| Draw / hit-test / drag-select | ✅ mouse + double-click word-select | ✅ tap + gestures | macOS word-select via `wordRange(at:)` |
| IME marked text (set/unmark) | ✅ | ✅ | |
| Insert / delete | ✅ | ✅ | grapheme-cluster–aware `deleteBackward` |
| Clipboard (cut / copy / paste / select all) | ✅ | ✅ | Engine-backed on both: Copy serializes the selection to Aozora notation and Paste parses it, so **ruby round-trips** copy/paste. macOS via `NSResponder` actions (Edit menu + ⌘X/C/V/A); iOS via `UIResponderStandardEditActions` + `canPerformAction` (the native edit menu — `UITextInteraction` gates items on these, it doesn't supply them). Undo/Redo still needs an `UndoManager` (deferred) |
| Arrow-key caret navigation | ✅ | ✅ | iOS via `UIKeyCommand` |
| Shift+arrow selection | ✅ | ✅ | |
| Selection-rect geometry | ✅ | ✅ | shared `selectionRects(for:)` |
| Native selection **handles / loupe / edit menu** | n/a (custom-drawn) | ✅ horizontal · ⚠️ vertical | via `UITextInteraction`; vertical is UIKit-limited (§3) |
| Caret rendering | ✅ | ✅ | vertical is engine-drawn on iOS (§3) |
| Selection stays valid after programmatic edit / orientation flip | ✅ (engine redraws) | ✅ | iOS refreshes `UITextInteraction` via `inputDelegate` (§5) |
| Vertical IME candidate placement | ✅ | ✅ | system-placed via `firstRect(for:)` (§4) |
| Ruby editing (apply/edit/remove, inline, geometry) | ✅ | ✅ | see `RubyEditing-Design.md` |

Input, selection, and ruby editing are at parity. The remaining gaps are iOS **vertical-text**
rendering details that stem from UIKit limitations, documented below.

## 2. Rendering ownership

- **macOS:** the engine owns all rendering — it draws text, selection highlight, and
  caret directly (`drawsSelectionHighlight` defaults `true`).
- **iOS horizontal:** `UITextInteraction` owns selection UI and the caret (native
  handles, loupe, edit menu, blinking caret). The engine draws only text
  (`drawsSelectionHighlight = false`).
- **iOS vertical:** the engine additionally draws the **caret** (see `drawsCaret`),
  because UIKit cannot render a vertical-text caret. Everything else stays native.

## 3. iOS vertical-text findings (this is the subtle part)

**UIKit has no vertical-text caret.** `UITextInteraction` always draws a *vertical
bar* whose length it takes from the caret rect's minor axis; given our wide-but-thin
vertical caret rect it collapses to a ~2pt stub. There is no rect we can return that
makes UIKit draw a horizontal bar.

**Solution:** the engine draws the caret in vertical mode, and UIKit's competing stub
is hidden **by tint, not by geometry** — `PorticoTextView.updateCaretTint()` sets
`tintColor = .clear` while vertical with no selection, restoring it for selections so
native handles / edit menu keep their color.

**Why not degenerate the caret rect?** `caretRect(for:)` is load-bearing for UIKit's
**cursor tracking**, not just drawing. Returning a zero-size rect suppressed the stub
but also starved the tracking the engine caret follows — the caret disappeared.
`caretRect` must stay honest; suppress the stub by color instead.

**Line-start caret clipping (fixed).** A separate geometry bug, exposed once the stub
was hidden: at a column top the vertical caret's `y` equalled the bounds top, so its
thickness spilled above the visible area and the caret vanished at every line start.
The caret now biases downward into the column (mirroring the horizontal caret's
rightward bias) so it stays in bounds. Regression test:
`verticalCaretAtLineStartStaysInBounds`.

**Remaining vertical limitation — selection handles / loupe.** UIKit's native
selection grab-handles and magnifier are unreliable under vertical CJK layout. Portico
keeps them native (they work in horizontal) and accepts UIKit's behavior in vertical
rather than reimplementing selection UI. Not currently addressed.

## 4. iOS IME candidate placement (verified — no gap)

Unlike macOS (which needs manual popup placement in `firstRect(forCharacterRange:)`),
iOS has **no floating candidate popup to place** for the soft keyboard — candidates
are keyboard-attached. With a hardware keyboard the system *does* show a floating
candidate list near the caret, positioned via `firstRect(for:)`, which already returns
a correct vertical column rect (from the engine's vertical-aware
`rect(forCharacterRange:)`). Verified on-device: vertical Japanese composition places
the candidate list correctly beside the column. **No code change needed** — the
earlier "vertical IME candidate placement" parity item was false parity.

## 5. Selection sync after programmatic changes

A programmatic text change (e.g. `setRuby`) or an orientation flip reflows the layout, so a
live selection's **geometry** changes even though its range doesn't. On **macOS** the engine
draws the selection, so it re-renders correctly on `setNeedsDisplay`. On **iOS** the selection
UI is `UITextInteraction`'s and is **cached** — it only refreshes on `inputDelegate`
notification. So `PorticoView.updateUIView` brackets external changes: `textWillChange` /
`textDidChange` around a text update, and `selectionWillChange` / `selectionDidChange` around an
orientation change, so UIKit re-queries handle geometry instead of leaving handles stale. The
`text != …` guard means these fire only on genuine external changes, not typing round-trips.

## 6. Minor / non-actionable

- **`baseWritingDirection`** returns `.leftToRight` always. `NSWritingDirection` has no
  vertical value, so there is no more-correct return; verticality is conveyed via
  `UITextSelectionRect.isVertical` (already set). Not a fixable gap.
- **`firstRect(for:)`** returns the first intersecting line segment of a range — correct
  per the "first rectangle" contract, not whole-range geometry.
- **No sticky caret column (desired-x).** Moving up across a shorter line then back down can
  drift horizontally — the caret follows the intermediate line's width instead of remembering
  its origin column. Engine-level (`moveCursor` / `index(from:moving:)`), so it affects both
  platforms. Not addressed.
- **`position(within:farthestIn:)`** is a `nil` stub — line-start/line-end layout navigation
  (e.g. macOS ⌘←/→ semantics via `UITextInput`) isn't wired. Arrow and Shift+Arrow navigation
  route through `position(from:in:)` / `characterRange(byExtending:)`, which are implemented.

## 7. Future upgrade path

The sanctioned long-term fix for the vertical caret (and potentially handles) is
**iOS 17+ `UITextSelectionDisplayInteraction` with a custom `cursorView`** — supply a
horizontal cursor view while UIKit keeps placement, blinking, and tracking. It would
replace the tint-suppression hybrid and could also address vertical selection handles.
Deferred: the package floor is iOS 16, so it needs an availability-gated dual path.
