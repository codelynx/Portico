// Phase 3 (editing) — §6 insertion attribute-edge rule.
// Inserted text joins a ruby group only when it lands strictly *inside* one; at a group
// boundary it is plain text. See Docs/RubyEditing-Design.md §6.
import Testing
import Foundation
import CoreText
@testable import Portico

private let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)

private func hasRuby(_ s: NSAttributedString, at index: Int) -> Bool {
	guard index >= 0, index < s.length else { return false }
	return s.attribute(rubyKey, at: index, effectiveRange: nil) != nil
}

private func editEngine(_ notation: String) -> PorticoTextLayoutEngine {
	PorticoTextLayoutEngine(
		attributedString: PorticoRuby.parse(notation),
		orientation: .horizontal,
		bounds: CGSize(width: 400, height: 400)
	)
}

@Test func typingAfterRubyBaseIsPlain() {
	// The reported bug: caret at the end boundary of 漢字《かんじ》, type — must NOT extend ruby.
	let e = editEngine("漢字《かんじ》") // base [0,2)
	e.cursorIndex = 2                    // right after 字 (end boundary)
	e.insertText("あ")
	#expect(e.attributedString.string == "漢字あ")
	#expect(hasRuby(e.attributedString, at: 0))
	#expect(hasRuby(e.attributedString, at: 1))
	#expect(!hasRuby(e.attributedString, at: 2)) // inserted char is plain
}

@Test func typingInsideRubyBaseExtendsGroup() {
	// Strictly interior insertion joins the group (§6).
	let e = editEngine("漢字《かんじ》") // base [0,2)
	e.cursorIndex = 1                    // between 漢 and 字
	e.insertText("々")
	#expect(e.attributedString.string == "漢々字")
	#expect(hasRuby(e.attributedString, at: 0))
	#expect(hasRuby(e.attributedString, at: 1)) // inserted char joined the group
	#expect(hasRuby(e.attributedString, at: 2))
}

@Test func typingBeforeRubyBaseIsPlain() {
	let e = editEngine("漢字《かんじ》") // base [0,2)
	e.cursorIndex = 0                    // start boundary
	e.insertText("x")
	#expect(e.attributedString.string == "x漢字")
	#expect(!hasRuby(e.attributedString, at: 0)) // inserted char is plain
	#expect(hasRuby(e.attributedString, at: 1))
	#expect(hasRuby(e.attributedString, at: 2))
}

@Test func typingBetweenTwoAdjacentGroupsIsPlain() {
	// Junction between 東京《…》 and 大学《…》 is a boundary for both — inserted text is plain.
	let e = editEngine("東京《とうきょう》大学《だいがく》") // [0,2) and [2,4)
	e.cursorIndex = 2                                      // between 京 and 大
	e.insertText("・")
	#expect(e.attributedString.string == "東京・大学")
	#expect(hasRuby(e.attributedString, at: 1))  // 京
	#expect(!hasRuby(e.attributedString, at: 2)) // ・ plain
	#expect(hasRuby(e.attributedString, at: 3))  // 大
}

@Test func typingInPlainTextStaysPlain() {
	let e = editEngine("ふつうの文")
	e.cursorIndex = 2
	e.insertText("X")
	#expect(e.attributedString.string == "ふつXうの文")
	#expect(!hasRuby(e.attributedString, at: 2))
}
