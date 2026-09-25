import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import Portico

// MARK: - Empty-document caret (MangaLoft placement-v2 S4)
//
// A laid-out EMPTY document must still produce a caret rect: the host may
// hide all editor chrome in the empty state, leaving the caret as the
// editor's only visible artifact. The synthesized rect is probe-derived
// (one ideographic space carrying `typingAttributes` laid out in the same
// frame), so the contract here is PARITY: the empty caret sits exactly
// where a one-character document's index-0 caret sits — for both
// orientations — because that is where the first typed glyph will land.

private func font(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
	#if canImport(UIKit)
	return [.font: UIFont(name: "HiraMinProN-W3", size: size) ?? UIFont.systemFont(ofSize: size)]
	#else
	return [.font: NSFont(name: "HiraMinProN-W3", size: size) ?? NSFont.systemFont(ofSize: size)]
	#endif
}

private func engines(
	orientation: PorticoLayoutOrientation, bounds: CGSize
) -> (empty: PorticoTextLayoutEngine, oneChar: PorticoTextLayoutEngine) {
	let empty = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: ""),
		orientation: orientation, bounds: bounds)
	empty.typingAttributes = font(14)
	let oneChar = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: "あ", attributes: font(14)),
		orientation: orientation, bounds: bounds)
	return (empty, oneChar)
}

@Test func emptyVerticalDocumentCaretIsNonZeroAndMatchesFirstCharCaret() {
	let (empty, oneChar) = engines(orientation: .vertical, bounds: CGSize(width: 60, height: 200))
	let caret = empty.caretRect(for: 0)
	#expect(caret.width > 0 && caret.height > 0, "empty editor must show a caret")
	// Vertical caret is a horizontal bar at the first column's head (the
	// frame's top-RIGHT region).
	#expect(caret.width > caret.height)
	let reference = oneChar.caretRect(for: 0)
	#expect(abs(caret.origin.x - reference.origin.x) < 0.5)
	#expect(abs(caret.origin.y - reference.origin.y) < 0.5)
}

@Test func emptyHorizontalDocumentCaretIsNonZeroAndMatchesFirstCharCaret() {
	let (empty, oneChar) = engines(orientation: .horizontal, bounds: CGSize(width: 200, height: 60))
	let caret = empty.caretRect(for: 0)
	#expect(caret.width > 0 && caret.height > 0, "empty editor must show a caret")
	// Horizontal caret is a vertical bar at the first line's head.
	#expect(caret.height > caret.width)
	let reference = oneChar.caretRect(for: 0)
	#expect(abs(caret.origin.x - reference.origin.x) < 0.5)
	#expect(abs(caret.origin.y - reference.origin.y) < 0.5)
}

@Test func emptyCenterAlignedHorizontalCaretMatchesFirstCharCaret() {
	// Review F3: the probe must MERGE the typing attributes' paragraph
	// style, not replace it — a center-aligned empty editor's caret sits
	// mid-line, exactly where the first typed character will land.
	let bounds = CGSize(width: 200, height: 60)
	let paragraph = NSMutableParagraphStyle()
	paragraph.alignment = .center
	var attrs = font(14)
	attrs[.paragraphStyle] = paragraph
	let empty = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: ""),
		orientation: .horizontal, bounds: bounds)
	empty.typingAttributes = attrs
	let oneChar = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: "\u{3000}", attributes: attrs),
		orientation: .horizontal, bounds: bounds)
	let caret = empty.caretRect(for: 0)
	let reference = oneChar.caretRect(for: 0)
	#expect(caret.origin.x > 20, "center alignment must move the empty caret off the head")
	#expect(abs(caret.origin.x - reference.origin.x) < 0.5)
	#expect(abs(caret.origin.y - reference.origin.y) < 0.5)
}

@Test func zeroBoundsEmptyDocumentCaretStaysZero() {
	// Never-laid-out engines (bounds .zero) keep the old contract — no
	// frame, no caret.
	let engine = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: ""),
		orientation: .vertical, bounds: .zero)
	#expect(engine.caretRect(for: 0) == .zero)
}

// ⛔ A box SMALLER than one line pitch (MangaLoft's empty 14 pt vertical editor sits at a 24–25 pt
// minimum; the ruby-aware pitch is wider). The probe used to lay out in the box itself, get no
// line, and return a zero caret — the empty editor showed nothing until the first keystroke
// (artist report, 2026-09-25). The caret must still show, at the writing-start corner.
@Test(arguments: [true, false])
func emptyCaretShowsInABoxSmallerThanOneLine(vertical: Bool) {
	let orientation: PorticoLayoutOrientation = vertical ? .vertical : .horizontal
	let box = CGSize(width: 25, height: 25)
	let (empty, _) = engines(orientation: orientation, bounds: box)
	let caret = empty.caretRect(for: 0)
	#expect(caret.width > 0 && caret.height > 0, "empty editor must show a caret in a small box")
	// At the writing start: the TOP (Core Text y-up → near maxY) and, for vertical, the RIGHT
	// column; for horizontal, the LEFT edge.
	#expect(caret.maxY <= box.height + 0.5)
	#expect(caret.maxY >= box.height - 30)
	if orientation == .vertical {
		#expect(caret.maxX >= box.width - 2 && caret.maxX <= box.width + 30)
	} else {
		#expect(caret.minX <= 2)
	}
}

/// The small-box path matches the large-box path once both are pinned at the writing start:
/// the caret's offset from the TOP-RIGHT (vertical) / TOP-LEFT (horizontal) corner is the same.
@Test(arguments: [true, false])
func emptyCaretKeepsItsCornerOffsetInASmallBox(vertical: Bool) {
	let orientation: PorticoLayoutOrientation = vertical ? .vertical : .horizontal
	let small = CGSize(width: 25, height: 25), large = CGSize(width: 200, height: 200)
	let s = engines(orientation: orientation, bounds: small).empty.caretRect(for: 0)
	let l = engines(orientation: orientation, bounds: large).empty.caretRect(for: 0)
	#expect(abs((small.height - s.maxY) - (large.height - l.maxY)) < 0.5, "same distance from the top")
	if orientation == .vertical {
		#expect(abs((small.width - s.maxX) - (large.width - l.maxX)) < 0.5, "same distance from the right")
	} else {
		#expect(abs(s.minX - l.minX) < 0.5, "same distance from the left")
	}
}
