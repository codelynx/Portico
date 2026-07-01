import Testing
import Foundation
import CoreGraphics
@testable import Portico

private func engine(_ s: String, orientation: PorticoLayoutOrientation = .horizontal) -> PorticoTextLayoutEngine {
	PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: s),
		orientation: orientation,
		bounds: CGSize(width: 2000, height: 2000) // wide/tall enough that lines don't wrap
	)
}

// MARK: - Engine selection geometry (backs iOS UITextInput.selectionRects)

@Test func selectionRectsEmptyForZeroLengthRange() {
	// A caret (zero-length) has no selection rects.
	#expect(engine("hello world").selectionRects(for: NSRange(location: 3, length: 0)).isEmpty)
}

@Test func selectionRectsSingleLineIsOneRect() {
	let rects = engine("hello world").selectionRects(for: NSRange(location: 0, length: 5))
	#expect(rects.count == 1)
	#expect(rects[0].width > 0 && rects[0].height > 0)
}

@Test func selectionRectsSpanOneRectPerLine() {
	// Selecting across three explicit lines yields one rect per line (multi-line,
	// unlike rect(forCharacterRange:) which returns only the first).
	let text = "line one\nline two\nline three"
	let rects = engine(text).selectionRects(for: NSRange(location: 0, length: (text as NSString).length))
	#expect(rects.count == 3)
	#expect(rects.allSatisfy { $0.width > 0 && $0.height > 0 })
}

@Test func selectionRectsWorkInVerticalOrientation() {
	let text = "縦書き\nテスト"
	let rects = engine(text, orientation: .vertical).selectionRects(for: NSRange(location: 0, length: (text as NSString).length))
	#expect(rects.count == 2)
	#expect(rects.allSatisfy { $0.width > 0 && $0.height > 0 })
}

// MARK: - Selection anchor consistency (external selection → Shift+Arrow)

@Test func externalSelectionThenShiftArrowExtends() {
	// Simulates UIKit setting a non-empty selection (via selectedTextRange), then a
	// Shift+Arrow. Before setSelectedRange seeded the anchor, this failed to extend.
	let e = engine("hello world")
	e.setSelectedRange(NSRange(location: 0, length: 5)) // "hello"
	#expect(e.selectionRange == NSRange(location: 0, length: 5))
	e.moveCursor(direction: .right, modifySelection: true)
	#expect(e.selectionRange == NSRange(location: 0, length: 6)) // extended, anchor at 0
}

@Test func setSelectedRangeCollapsesZeroLengthToCaret() {
	let e = engine("hello world")
	e.setSelectedRange(NSRange(location: 3, length: 0))
	#expect(e.selectionRange == nil)
	#expect(e.cursorIndex == 3)
}

@Test func drawsSelectionUIDefaultsOn() {
	// macOS relies on the engine drawing its own caret/selection.
	#expect(engine("x").drawsSelectionUI == true)
}
