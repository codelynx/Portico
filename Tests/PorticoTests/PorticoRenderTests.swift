import Testing
import Foundation
import CoreGraphics
@testable import Portico

// MARK: - Render tests (PR-1: drawText(in:) display-only render)
//
// Test posture per Docs/MangaLettering-Extensions-Plan.md: in-process A/B comparisons
// only (never golden images), coverage/pixel assertions with tolerance — but for
// same-run same-engine renders, buffer equality is exact and safe.

private let renderSize = CGSize(width: 200, height: 200)

private func makeEngine(
	_ s: String,
	orientation: PorticoLayoutOrientation = .horizontal
) -> PorticoTextLayoutEngine {
	PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: s),
		orientation: orientation,
		bounds: renderSize
	)
}

/// Renders via the given draw call into a fresh RGBA bitmap and returns the pixel bytes.
private func pixels(_ draw: (CGContext) -> Void, size: CGSize = renderSize) -> [UInt8] {
	let width = Int(size.width), height = Int(size.height)
	let bytesPerRow = width * 4
	var data = [UInt8](repeating: 0, count: bytesPerRow * height)
	data.withUnsafeMutableBytes { buffer in
		let context = CGContext(
			data: buffer.baseAddress,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: bytesPerRow,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		)!
		draw(context)
	}
	return data
}

// MARK: drawText omits the caret (the vertical spurious-caret gap)

@Test func verticalDisplayRenderOmitsCaret() {
	// In vertical orientation drawsCaret is unconditionally true, so the editing
	// render paints a caret whenever there's no selection — the display render must not.
	let e = makeEngine("こんにちは世界", orientation: .vertical)
	e.cursorIndex = 3
	#expect(e.drawsCaret)
	let editing = pixels { e.draw(in: $0) }
	let display = pixels { e.drawText(in: $0) }
	#expect(editing != display) // caret pixels present in the editing render only
}

@Test func displayRenderIsInvariantUnderCursorState() {
	let e = makeEngine("こんにちは世界", orientation: .vertical)
	e.cursorIndex = 0
	let atStart = pixels { e.drawText(in: $0) }
	e.cursorIndex = 6
	let atEnd = pixels { e.drawText(in: $0) }
	#expect(atStart == atEnd)
}

// MARK: drawText omits the selection highlight

@Test func displayRenderIsInvariantUnderSelectionState() {
	let e = makeEngine("hello world")
	e.drawsSelectionHighlight = true
	let noSelection = pixels { e.drawText(in: $0) }
	e.setSelectedRange(NSRange(location: 0, length: 5))
	let withSelection = pixels { e.drawText(in: $0) }
	#expect(noSelection == withSelection)

	// ...while the editing render does paint the highlight.
	let editingWithSelection = pixels { e.draw(in: $0) }
	#expect(editingWithSelection != withSelection)
}

// MARK: drawText == draw when no editing chrome applies (documented equivalence)

@Test func displayRenderMatchesEditingRenderWithoutChrome() {
	// Horizontal + selection highlighting off → drawsCaret is false and no selection
	// is painted, so the two paths must be the same pixels: proves drawText is
	// exactly the text core the editing render uses (in-process A/B). The fixture is
	// built via PorticoRuby.parse so the parity claim covers a real CTRubyAnnotation,
	// not literal 《》 glyphs.
	let e = PorticoTextLayoutEngine(
		attributedString: PorticoRuby.parse("hello 世界《せかい》ruby"),
		orientation: .horizontal,
		bounds: renderSize
	)
	e.drawsSelectionHighlight = false
	#expect(!e.drawsCaret)
	let editing = pixels { e.draw(in: $0) }
	let display = pixels { e.drawText(in: $0) }
	#expect(editing == display)
	// Sanity: something was actually drawn.
	#expect(display.contains { $0 != 0 })
}

// MARK: no layout = no-op

@Test func displayRenderWithoutLayoutIsNoop() {
	let e = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: "text"),
		orientation: .vertical,
		bounds: .zero // no layout — updateLayout bails on zero bounds
	)
	let display = pixels { e.drawText(in: $0) }
	#expect(display.allSatisfy { $0 == 0 })
}
