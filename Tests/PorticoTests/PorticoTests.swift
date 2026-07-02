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

@Test func drawsSelectionHighlightDefaultsOn() {
	// macOS relies on the engine drawing its own selection highlight.
	#expect(engine("x").drawsSelectionHighlight == true)
}

@Test func drawsCaretOwnsVerticalEvenWhenHighlightOff() {
	// iOS turns off the highlight (UIKit owns selection), but the engine must still own
	// the caret in vertical (UIKit can't render one) and cede it in horizontal.
	let v = engine("x", orientation: .vertical)
	v.drawsSelectionHighlight = false
	#expect(v.drawsCaret == true)
	let h = engine("x", orientation: .horizontal)
	h.drawsSelectionHighlight = false
	#expect(h.drawsCaret == false)
}

@Test func verticalCaretAtLineStartStaysInBounds() {
	// Regression: at the top of a column the caret's y equalled the bounds top, so its
	// thickness spilled above the visible area and the caret vanished. It must stay inside.
	let text = "吾輩は猫である。\nどこで生れたか。\nPortico engine."
	let h: CGFloat = 400
	let e = PorticoTextLayoutEngine(attributedString: NSAttributedString(string: text), orientation: .vertical, bounds: CGSize(width: 400, height: h))
	let ns = text as NSString
	var starts = [0]
	for i in 0..<ns.length where ns.character(at: i) == 10 { starts.append(i + 1) }
	for s in starts {
		let r = e.caretRect(for: s)
		#expect(r.maxY <= h, "caret at line-start idx \(s) spills above bounds: \(r)")
		#expect(r.minY >= 0, "caret at line-start idx \(s) spills below bounds: \(r)")
	}
}

// MARK: - Grapheme-aware deleteBackward (non-BMP / combining sequences)

@Test func deleteBackwardRemovesWholeSurrogatePair() {
	let e = engine("a𩸽") // 𩸽 = U+29E3D, a surrogate pair (2 UTF-16 units) at [1,3)
	e.cursorIndex = 3
	e.deleteBackward()
	#expect(e.attributedString.string == "a") // whole character removed, not a lone surrogate
	#expect(e.cursorIndex == 1)
}

@Test func deleteBackwardRemovesWholeCombiningSequence() {
	let e = engine("ae\u{0301}") // "aé" — e + combining acute (one grapheme, 2 units)
	e.cursorIndex = 3
	e.deleteBackward()
	#expect(e.attributedString.string == "a") // whole é removed, not just the accent
	#expect(e.cursorIndex == 1)
}
