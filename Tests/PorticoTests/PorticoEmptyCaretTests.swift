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
