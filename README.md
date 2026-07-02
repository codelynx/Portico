<img src="Artworks/Portico.png" alt="Portico" width="128" />

# Portico

A reusable **horizontal + vertical Japanese text component with ruby (furigana) editing**, built
directly on **Core Text** for macOS and iOS. Portico owns the hard parts — layout in both writing
modes, hit-testing, selection, caret, IME, clipboard, and the ruby model — and exposes them as a
SwiftUI view or a headless engine. It is **framework-first**: it provides the primitives and
geometry; *your* app supplies the editing UI.

This README is written as a reference for engineers building a Japanese text editor: it covers
both what the component does (the user's point of view) and the API you call to embed it (the
client app's point of view).

## Screenshots

The same document — Sōseki's *I Am a Cat* with furigana — laid out both ways on both platforms,
showing selection and the in-place ruby editor.

|  | Horizontal | Vertical |
|---|---|---|
| **macOS** | <img src="Docs/images/macos-horizontal.png" width="380" alt="Portico on macOS, horizontal"> | <img src="Docs/images/macos-vertical.png" width="380" alt="Portico on macOS, vertical"> |
| **iOS** | <img src="Docs/images/ios-horizontal.png" width="380" alt="Portico on iOS, horizontal"> | <img src="Docs/images/ios-vertical.png" width="380" alt="Portico on iOS, vertical"> |

## What you get

From the **user's** side:

- **Horizontal and vertical** Japanese layout (横書き / 縦書き), switchable at runtime.
- **Ruby (furigana)** rendered above (horizontal) or right of (vertical) its base.
- Native **selection** (drag, double-click/tap word-select, handles), **caret**, and
  **arrow-key / Shift-arrow** navigation that follows the writing mode.
- **IME** marked text and candidate placement on both platforms.
- **Clipboard** — cut / copy / paste / select-all; copy carries ruby, so it survives paste.
- In-place **ruby editing** — select text, invoke a menu action, set/edit/remove the reading.

From the **integrator's** side:

- A SwiftUI **`PorticoView`**, or the platform-neutral **`PorticoTextLayoutEngine`** to drive
  your own `NSView`/`UIView`.
- A plain-text **ruby notation** (`PorticoRuby`) for authoring and persistence.
- Geometry + a **menu seam** to build your own editing UI without reimplementing layout.

## Requirements

macOS 13+ · iOS 16+ · Swift 6.2 toolchain.

## Installation

Swift Package Manager — add the dependency in `Package.swift`:

```swift
.package(url: "https://github.com/codelynx/Portico.git", from: "0.2.0")
```

Then `import Portico`.

## Concepts

Two layers, cleanly separated:

- **`PorticoTextLayoutEngine`** — platform-neutral, pure Core Text. Holds the `NSAttributedString`,
  the orientation, the selection/caret/marked state, and does all layout, hit-testing, drawing, and
  geometry. No UIKit/AppKit selection UI.
- **`PorticoView`** (SwiftUI) / **`PorticoTextView`** (`NSView` on macOS, `UIView`+`UITextInput`
  on iOS) — thin wrappers that connect the engine to the platform: events, IME, native selection
  UI, clipboard, and the menu seam.

**Ruby model.** A ruby group is *one contiguous base range + one reading*, stored as a
`CTRubyAnnotation` attribute over the base — the reading is **not** in the backing string, so
string indices, hit-testing, and selection are unaffected. The public interchange format is
**Aozora-style notation** (`漢字《かんじ》`); `PorticoRuby.parse` / `serialize` convert between text
and attributed string.

**Rendering ownership** differs per platform (this is the source of most platform-specific
behavior): macOS draws selection + caret itself; iOS lets `UITextInteraction` own them (handles,
loupe, edit menu). See [Platform parity](Docs/PlatformParity.md).

## Quick start

```swift
import SwiftUI
import Portico

struct ContentView: View {
    @State private var text = PorticoRuby.parse("吾輩《わがはい》は猫《ねこ》である。")
    @State private var orientation: PorticoLayoutOrientation = .vertical

    var body: some View {
        PorticoView(text: $text, orientation: orientation)
    }
}
```

## Using the API (client app's point of view)

### 1. Author & persist ruby

Notation is the authoring and persistence format:

| Form | Example | Base | Reading |
|------|---------|------|---------|
| **Auto** (kanji) | `漢字《かんじ》` | the preceding run of kanji | かんじ |
| **Explicit** (`｜`) | `｜大人《おとな》` | text from `｜` up to `《` | おとな |

```swift
let attributed = PorticoRuby.parse("吾輩《わがはい》は猫《ねこ》である。")
let notation   = PorticoRuby.serialize(attributed)   // back to text; parse(serialize(x)) round-trips

// Apply base attributes (font/colour) to the whole string while attaching ruby:
let styled = PorticoRuby.parse("猫《ねこ》", attributes: [.font: someFont])
```

`serialize` emits **minimal** notation — it drops the `｜` wherever auto-detection recovers the same
base, so output reads like hand-authored Aozora. Round-trip is guaranteed for text without literal
`《`, `》`, `｜` (v1 has no escaping).

### 2. Render & switch orientation

Bind the text and flip `orientation` at runtime; the view re-lays out.

```swift
PorticoView(text: $text, orientation: isVertical ? .vertical : .horizontal)
```

### 3. Observe the selection

```swift
PorticoView(text: $text, orientation: orientation, selectedRange: $selectedRange)
// selectedRange: Binding<NSRange?> — nil when collapsed to a caret.
```

### 4. Build an in-place ruby editor

Set `onSelectionMenuAction` and Portico adds a **menu item** to the iOS edit menu and the macOS
right-click menu, handing your handler the selected range plus a popover **anchor rect** (top-left
view coordinates). You supply the reading UI; you write the change with `setRuby`. Opt-out by
default — no action, no menu item. For a macOS `Edit ▸ …` command, wire a main-menu item to the
view's `performSelectionMenuAction(_:)` (the [Example](Example/Example/ExampleApp.swift) does this
with a `⇧⌘R` shortcut).

```swift
struct RubyEditor: View {
    @State private var text = PorticoRuby.parse("吾輩《わがはい》は猫《ねこ》である。")
    @State private var editing: (range: NSRange, anchor: CGRect)?
    @State private var reading = ""

    var body: some View {
        PorticoView(
            text: $text,
            orientation: .vertical,
            onSelectionMenuAction: PorticoSelectionMenuAction(title: "Ruby…") { range, anchor in
                // Prefill only when the selection is exactly an existing group's base (an edit);
                // otherwise start empty (add / replace over the selection).
                let group = PorticoRuby.rubyGroup(at: range.location, in: text)
                reading = (group?.base == range ? group?.reading : nil) ?? ""
                editing = (range, anchor)
            }
        )
        .overlay(alignment: .topLeading) {
            if let edit = editing {
                TextField("reading", text: $reading)     // position at edit.anchor in your layout
                    .onSubmit {
                        let m = NSMutableAttributedString(attributedString: text)
                        PorticoRuby.setRuby(reading.isEmpty ? nil : reading, for: edit.range, in: m)
                        text = m                          // empty reading removes the ruby
                        editing = nil
                    }
            }
        }
    }
}
```

Supporting queries for editing UI:

```swift
PorticoRuby.rubyGroup(at: index, in: attributed)     // (base, reading)? at a character
PorticoRuby.rubyGroups(in: range, of: attributed)    // groups intersecting a range
PorticoRuby.setRuby(_:for:in:)                        // add / edit / remove (nil, empty, or whitespace-only removes)
```

Inline authoring also works while typing: entering `漢字《かんじ》` converts to a ruby group on the
closing `》` (committed text only, never inside IME composition).

### 5. Clipboard

Cut / Copy / Paste / Select-All are built in on both platforms (menu items and ⌘/hardware
shortcuts). Copy serializes the selection to notation and Paste parses it, so **ruby survives
copy/paste** within Portico; plain text copies/pastes as-is.

### 6. Drive the engine directly (headless or custom view)

For a fully custom view, or offscreen layout/measurement, use the engine without SwiftUI:

```swift
let engine = PorticoTextLayoutEngine(
    attributedString: PorticoRuby.parse("吾輩《わがはい》は猫《ねこ》である"),
    orientation: .vertical,
    bounds: CGSize(width: 400, height: 600)
)

// In your draw path:
engine.update(bounds: view.bounds.size)
engine.draw(in: cgContext)

// Interaction:
let i     = engine.stringIndex(for: point)          // hit-test → character index
let rects = engine.selectionRects(for: range)       // one rect per line/column the range spans
let caret = engine.caretRect(for: engine.cursorIndex)
engine.setSelectedRange(range)                       // set caret/selection
engine.moveCursor(direction: .down, modifySelection: true)   // orientation-aware nav
let anchor = engine.anchorRectForSelection()         // first-segment popover anchor (top-left)
```

Observe changes with `engine.textDidChange` / `engine.selectionDidChange`.

## Platform behavior

Input, selection, ruby editing, and clipboard are at parity across macOS and iOS. The remaining
differences are iOS **vertical-text** rendering details rooted in UIKit limits (native selection
handles/loupe in vertical). Full matrix and rationale: [Platform parity](Docs/PlatformParity.md).

## Status & limitations

Layout, rendering, selection, IME, ruby (parse / serialize / edit), navigation, and clipboard are
in place on both platforms. Consciously deferred:

- **Undo / Redo** — no `UndoManager` wired to the engine yet.
- **Escaping** of literal `《` / `》` / `｜` in body text (they're treated as control characters).
- **Mono-/jukugo-ruby** (per-character readings) — v1 is group-ruby.
- **Public ruby styling knobs** (alignment / overhang / scale) — v1 uses sane fixed defaults.
- iOS **vertical** native selection handles/loupe.

## Documentation

- [Ruby support](Docs/RubySupport.md) — notation, parsing, rendering, and the clipboard round-trip.
- [Ruby editing design](Docs/RubyEditing-Design.md) — the editing model and the selection-menu seam.
- [Platform parity](Docs/PlatformParity.md) — iOS ↔ macOS behavior and known limits.
- [Changelog](CHANGELOG.md).

A runnable demo is in [`Example/`](Example/): horizontal ⇄ vertical toggle, ruby rendering, and
the select → menu → popover editor.

## License

Portico is released under the **MIT License** — see [LICENSE](LICENSE).
