<img src="Artworks/Portico.png" alt="Portico" width="128" />

# Portico

A custom, high-performance text engine built directly on **Core Text** for macOS and
iOS. Portico handles native hit-testing, selection, and input events itself, so it can
switch seamlessly between **horizontal and vertical** layouts — including Japanese
**ruby (furigana)** — without giving up standard text-editor behavior.

## Screenshots

The same document — Sōseki's *I Am a Cat* with furigana — laid out both ways on both
platforms, with the in-place ruby editor open.

|  | Horizontal | Vertical |
|---|---|---|
| **macOS** | <img src="Docs/images/macos-horizontal.png" width="380" alt="Portico on macOS, horizontal"> | <img src="Docs/images/macos-vertical.png" width="380" alt="Portico on macOS, vertical"> |
| **iOS** | <img src="Docs/images/ios-horizontal.png" width="380" alt="Portico on iOS, horizontal"> | <img src="Docs/images/ios-vertical.png" width="380" alt="Portico on iOS, vertical"> |

## Features

- **Horizontal & vertical** Japanese text layout (縦書き / 横書き).
- **Ruby (furigana)** via Aozora-style notation: `漢字《かんじ》`.
- Native **selection**, caret, hit-testing, and keyboard navigation.
- **IME** support — marked text and candidate positioning on both platforms.
- SwiftUI view (`PorticoView`) or drive the layout engine directly.

## Requirements

macOS 13+ · iOS 16+ · Swift 6.2 toolchain.

## Installation

Swift Package Manager — add the dependency in `Package.swift`:

```swift
.package(url: "https://github.com/codelynx/Portico.git", from: "0.2.0")
```

## Usage

```swift
import SwiftUI
import Portico

struct ContentView: View {
    // Author ruby from notation; render it horizontally or vertically.
    @State private var text = PorticoRuby.parse("吾輩《わがはい》は猫《ねこ》である")
    @State private var orientation: PorticoLayoutOrientation = .vertical

    var body: some View {
        PorticoView(text: $text, orientation: orientation)
    }
}
```

Persist ruby back to text with `PorticoRuby.serialize(_:)` (round-trips with `parse`),
or drive the engine directly via `PorticoTextLayoutEngine`.

A runnable demo is in [`Example/`](Example/) (horizontal ⇄ vertical toggle, ruby).

## Documentation

- [Ruby support](Docs/RubySupport.md) — notation, parsing, and rendering.
- [Platform parity](Docs/PlatformParity.md) — iOS ↔ macOS behavior and known limits.

## Status

Core layout, rendering, selection, IME, and ruby (parse + serialize) are in place on
both platforms. Live ruby **editing** semantics and a few iOS vertical-text niceties
(native selection handles in vertical) are still evolving — see the parity doc.
