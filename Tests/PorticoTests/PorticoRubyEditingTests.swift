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

// MARK: - §6 post-edit normalization: ruby survives edits and round-trips

/// The buffer must serialize → parse back to the same text + ruby-group semantics (§9).
private func roundTrips(_ engine: PorticoTextLayoutEngine) -> Bool {
	let s = engine.attributedString
	let reparsed = PorticoRuby.parse(PorticoRuby.serialize(s))
	guard reparsed.string == s.string else { return false }
	let a = PorticoRuby.rubyGroups(in: NSRange(location: 0, length: s.length), of: s)
	let b = PorticoRuby.rubyGroups(in: NSRange(location: 0, length: reparsed.length), of: reparsed)
	return a.map { "\($0.base)=\($0.reading)" } == b.map { "\($0.base)=\($0.reading)" }
}

@Test func deleteInsideBaseKeepsContiguousRubyAndRoundTrips() {
	let e = editEngine("｜漢字学《かんじがく》") // base [0,3)
	#expect(e.attributedString.string == "漢字学")
	e.cursorIndex = 2
	e.deleteBackward() // delete 字 (interior)
	#expect(e.attributedString.string == "漢学")
	#expect(hasRuby(e.attributedString, at: 0) && hasRuby(e.attributedString, at: 1))
	#expect(roundTrips(e))
}

@Test func deleteEntireBaseDropsGroupAndRoundTrips() {
	let e = editEngine("漢字《かんじ》の本") // "漢字の本", ruby [0,2)
	e.selectionRange = NSRange(location: 0, length: 2)
	e.deleteBackward()
	#expect(e.attributedString.string == "の本")
	#expect(PorticoRuby.rubyGroups(in: NSRange(location: 0, length: e.attributedString.length), of: e.attributedString).isEmpty)
	#expect(roundTrips(e))
}

@Test func deleteAcrossGroupBoundaryRoundTrips() {
	let e = editEngine("東京《とうきょう》都") // "東京都", ruby [0,2)
	e.selectionRange = NSRange(location: 1, length: 2) // 京都 (part of base + 都)
	e.deleteBackward()
	#expect(e.attributedString.string == "東")
	#expect(hasRuby(e.attributedString, at: 0)) // surviving 東 keeps ruby
	#expect(roundTrips(e))
}

@Test func adjacentGroupsAfterDeleteStaySeparateAndRoundTrip() {
	let e = editEngine("春《はる》と秋《あき》") // "春と秋", [0,1)=はる [2,3)=あき
	e.selectionRange = NSRange(location: 1, length: 1) // delete と
	e.deleteBackward()
	#expect(e.attributedString.string == "春秋")
	let groups = PorticoRuby.rubyGroups(in: NSRange(location: 0, length: e.attributedString.length), of: e.attributedString)
	#expect(groups.count == 2) // must NOT merge into one group
	#expect(roundTrips(e))
}

@Test func insertInsideBaseExtendsAndRoundTrips() {
	let e = editEngine("漢字《かんじ》")
	e.cursorIndex = 1
	e.insertText("々") // extends group to [0,3)
	#expect(e.attributedString.string == "漢々字")
	#expect(hasRuby(e.attributedString, at: 0) && hasRuby(e.attributedString, at: 1) && hasRuby(e.attributedString, at: 2))
	#expect(roundTrips(e))
}

@Test func markedTextAfterRubyBaseIsPlain() {
	// IME composition after a base must not inherit its ruby (same boundary rule as insertText).
	let e = editEngine("漢字《かんじ》") // [0,2)
	e.cursorIndex = 2
	e.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: nil)
	#expect(e.attributedString.string == "漢字か")
	#expect(hasRuby(e.attributedString, at: 0) && hasRuby(e.attributedString, at: 1))
	#expect(!hasRuby(e.attributedString, at: 2)) // composing char is plain
}

@Test func markedTextInsideRubyBaseInheritsGroup() {
	let e = editEngine("漢字《かんじ》")
	e.cursorIndex = 1
	e.setMarkedText("ん", selectedRange: NSRange(location: 1, length: 0), replacementRange: nil)
	#expect(e.attributedString.string == "漢ん字")
	#expect(hasRuby(e.attributedString, at: 1)) // interior composing text joins the group
}

@Test func deleteNewlineMergingRubyParagraphsRoundTrips() {
	let e = editEngine("春《はる》\n秋《あき》") // "春\n秋"
	e.cursorIndex = 2 // after the newline
	e.deleteBackward() // delete the newline
	#expect(e.attributedString.string == "春秋")
	#expect(PorticoRuby.rubyGroups(in: NSRange(location: 0, length: e.attributedString.length), of: e.attributedString).count == 2)
	#expect(roundTrips(e))
}

@Test func pastingAnnotatedRubyMidBaseSplitsGroupButRoundTrips() {
	// Not reachable via the String-based insertText/setMarkedText API; documents attribute-
	// store behavior for a future "paste attributed content" feature: inserting a ruby
	// fragment inside a base splits it into three valid groups that still round-trip.
	// Revisit normalization if/when attributed paste ships.
	let s = NSMutableAttributedString(attributedString: PorticoRuby.parse("漢字《かんじ》")) // [0,2)
	let fragment = PorticoRuby.parse("｜X《えっくす》")
	s.replaceCharacters(in: NSRange(location: 1, length: 0), with: fragment) // paste inside the base
	#expect(s.string == "漢X字")
	let groups = PorticoRuby.rubyGroups(in: NSRange(location: 0, length: s.length), of: s)
	#expect(groups.count == 3) // 漢=かんじ, X=えっくす, 字=かんじ
	#expect(PorticoRuby.parse(PorticoRuby.serialize(s)).string == s.string)
}

// MARK: - §5 editing primitives: setRuby / rubyGroup / rubyGroups

private func mutable(_ notation: String) -> NSMutableAttributedString {
	NSMutableAttributedString(attributedString: PorticoRuby.parse(notation))
}

@Test func setRubyAddsGroupToPlainText() {
	let s = NSMutableAttributedString(string: "漢字")
	PorticoRuby.setRuby("かんじ", for: NSRange(location: 0, length: 2), in: s)
	let g = PorticoRuby.rubyGroup(at: 0, in: s)
	#expect(g?.base == NSRange(location: 0, length: 2))
	#expect(g?.reading == "かんじ")
}

@Test func setRubyRemovesWithNil() {
	let s = mutable("漢字《かんじ》")
	PorticoRuby.setRuby(nil, for: NSRange(location: 0, length: 2), in: s)
	#expect(PorticoRuby.rubyGroup(at: 0, in: s) == nil)
	#expect(s.string == "漢字") // base text kept
}

@Test func setRubyRemovesWithEmptyOrWhitespace() {
	for empty in ["", "   ", "\n"] {
		let s = mutable("漢字《かんじ》")
		PorticoRuby.setRuby(empty, for: NSRange(location: 0, length: 2), in: s)
		#expect(PorticoRuby.rubyGroup(at: 0, in: s) == nil, "‘\(empty)’ should remove")
	}
}

@Test func setRubyReplacesIntersectingGroups() {
	// Range straddling two groups → both cleared (full ranges), one new group, no fragments.
	let s = mutable("東京《とうきょう》大学《だいがく》") // 東京[0,2) 大学[2,4)
	PorticoRuby.setRuby("よみ", for: NSRange(location: 1, length: 2), in: s) // covers 京大
	#expect(s.string == "東京大学")
	#expect(PorticoRuby.rubyGroup(at: 0, in: s) == nil)              // 東 — old ruby cleared
	#expect(PorticoRuby.rubyGroup(at: 1, in: s)?.reading == "よみ")
	#expect(PorticoRuby.rubyGroup(at: 2, in: s)?.reading == "よみ")
	#expect(PorticoRuby.rubyGroup(at: 3, in: s) == nil)              // 学 — old ruby cleared
	#expect(PorticoRuby.rubyGroups(in: NSRange(location: 0, length: 4), of: s).count == 1)
}

@Test func rubyGroupAtIndexBoundaries() {
	let s = mutable("a漢字《かんじ》") // "a漢字", ruby [1,3)
	#expect(s.string == "a漢字")
	#expect(PorticoRuby.rubyGroup(at: 0, in: s) == nil)             // 'a' plain
	#expect(PorticoRuby.rubyGroup(at: 1, in: s)?.base == NSRange(location: 1, length: 2))
	#expect(PorticoRuby.rubyGroup(at: 2, in: s)?.reading == "かんじ")
	#expect(PorticoRuby.rubyGroup(at: 3, in: s) == nil)             // end/out of bounds
}

@Test func rubyGroupsInRangeReturnsFullRanges() {
	let s = mutable("東京《とうきょう》大学《だいがく》")
	let all = PorticoRuby.rubyGroups(in: NSRange(location: 0, length: s.length), of: s)
	#expect(all.count == 2)
	#expect(all[0].base == NSRange(location: 0, length: 2) && all[0].reading == "とうきょう")
	#expect(all[1].base == NSRange(location: 2, length: 2) && all[1].reading == "だいがく")
	// A query touching only part of the first group still returns it whole.
	let partial = PorticoRuby.rubyGroups(in: NSRange(location: 0, length: 1), of: s)
	#expect(partial.count == 1 && partial[0].base == NSRange(location: 0, length: 2))
}

@Test func setRubyZeroLengthIsNoOp() {
	let s = mutable("漢字《かんじ》")
	PorticoRuby.setRuby("x", for: NSRange(location: 1, length: 0), in: s)
	#expect(PorticoRuby.rubyGroup(at: 0, in: s)?.reading == "かんじ") // unchanged
}

@Test func rubyGroupReturnsFullRangeAcrossStyleRuns() {
	// A secondary attribute over only part of the base splits the attribute runs; the group
	// query must still report the FULL base range (longestEffectiveRange), not a sub-run.
	let s = mutable("漢字《かんじ》") // ruby over [0,2)
	s.addAttribute(NSAttributedString.Key("test.bold"), value: true, range: NSRange(location: 0, length: 1))
	let g = PorticoRuby.rubyGroup(at: 1, in: s)
	#expect(g?.base == NSRange(location: 0, length: 2))
	#expect(g?.reading == "かんじ")
}

@Test func setRubyStoresReadingAsGiven() {
	// Trimming decides only removal; a non-blank reading is stored verbatim (normalization
	// is the client's call, per design §11).
	let s = NSMutableAttributedString(string: "漢字")
	PorticoRuby.setRuby(" か ん ", for: NSRange(location: 0, length: 2), in: s)
	#expect(PorticoRuby.rubyGroup(at: 0, in: s)?.reading == " か ん ")
}

@Test func setRubyRoundTrips() {
	// Acceptance criterion (§9): a setRuby-built state serializes and reparses identically.
	let s = NSMutableAttributedString(string: "東京は大学だ")
	PorticoRuby.setRuby("とうきょう", for: NSRange(location: 0, length: 2), in: s)
	PorticoRuby.setRuby("だいがく", for: NSRange(location: 3, length: 2), in: s)
	let reparsed = PorticoRuby.parse(PorticoRuby.serialize(s))
	#expect(reparsed.string == s.string)
	let a = PorticoRuby.rubyGroups(in: NSRange(location: 0, length: s.length), of: s)
	let b = PorticoRuby.rubyGroups(in: NSRange(location: 0, length: reparsed.length), of: reparsed)
	#expect(a.map { "\($0.base)=\($0.reading)" } == b.map { "\($0.base)=\($0.reading)" })
}

@Test func adjacentSameReadingGroupsStaySeparateAfterDelete() {
	// Two DIFFERENT groups with the SAME reading, made adjacent by a delete, must NOT merge —
	// CTRubyAnnotation instances are distinct objects, so the store keeps them as two runs.
	let e = editEngine("木《き》と気《き》") // 木=き, 気=き
	e.selectionRange = NSRange(location: 1, length: 1) // delete と
	e.deleteBackward()
	#expect(e.attributedString.string == "木気")
	let groups = PorticoRuby.rubyGroups(in: NSRange(location: 0, length: e.attributedString.length), of: e.attributedString)
	#expect(groups.count == 2) // not merged into one き group
	#expect(roundTrips(e))
}

@Test func replacingSelectionSpanningGroupsRoundTrips() {
	// Type over a selection straddling two groups: inserted text is plain (boundary rule),
	// the flanking groups shrink to their survivors, and the result still round-trips.
	let e = editEngine("東京《とうきょう》大学《だいがく》") // 東京[0,2) 大学[2,4)
	e.selectionRange = NSRange(location: 1, length: 2) // 京大
	e.insertText("X")
	#expect(e.attributedString.string == "東X学")
	#expect(hasRuby(e.attributedString, at: 0))  // 東 survivor of first group
	#expect(!hasRuby(e.attributedString, at: 1)) // X plain
	#expect(hasRuby(e.attributedString, at: 2))  // 学 survivor of second group
	#expect(roundTrips(e))
}

// MARK: - Step 4: ruby geometry primitives

@Test func rubyRectsMatchBaseSelectionRects() {
	let e = editEngine("漢字《かんじ》") // base [0,2)
	let rects = e.rects(forRubyGroupContaining: 0)
	#expect(!rects.isEmpty)
	#expect(rects.allSatisfy { $0.width > 0 && $0.height > 0 })
	#expect(rects == e.selectionRects(for: NSRange(location: 0, length: 2))) // same base geometry
}

@Test func rubyGeometryEmptyOffGroup() {
	let e = editEngine("漢字《かんじ》の") // "漢字の", ruby [0,2); の plain
	#expect(e.rects(forRubyGroupContaining: 2).isEmpty)
	#expect(e.anchorRect(forRubyGroupContaining: 2) == .null)
}

@Test func anchorRectEnclosesGroupRects() {
	let e = editEngine("漢字《かんじ》")
	let anchor = e.anchorRect(forRubyGroupContaining: 1)
	#expect(anchor != .null)
	for r in e.rects(forRubyGroupContaining: 1) {
		#expect(anchor.union(r) == anchor) // the anchor contains every base rect
	}
}

@Test func rubyGroupAtPointResolvesBaseTap() {
	let e = editEngine("a漢字《かんじ》") // "a漢字", ruby [1,3)
	let kanRect = e.rect(forCharacterRange: NSRange(location: 1, length: 1)) // 漢, inside the base
	let g = e.rubyGroup(at: CGPoint(x: kanRect.midX, y: kanRect.midY))
	#expect(g?.base == NSRange(location: 1, length: 2))
	#expect(g?.reading == "かんじ")
	// A point past the text resolves to no group.
	#expect(e.rubyGroup(at: CGPoint(x: 100000, y: kanRect.midY)) == nil)
}

@Test func rubyGroupAtPointHitsTrailingHalfOfSingleKanjiBase() {
	// Containment vs caret: a tap on the trailing half of a one-kanji base must still find the
	// group (the old caret-index path missed it), while the leading half of the next plain
	// glyph must not.
	let e = editEngine("漢《かん》の") // "漢の", ruby [0,1)
	let kan = e.rect(forCharacterRange: NSRange(location: 0, length: 1)) // 漢
	#expect(e.rubyGroup(at: CGPoint(x: kan.maxX - 1, y: kan.midY))?.base == NSRange(location: 0, length: 1))
	#expect(e.rubyGroup(at: CGPoint(x: kan.maxX + 1, y: kan.midY)) == nil) // の (plain)
}

@Test func rubyGeometryWorksInVertical() {
	let e = PorticoTextLayoutEngine(
		attributedString: PorticoRuby.parse("漢字《かんじ》"),
		orientation: .vertical,
		bounds: CGSize(width: 400, height: 400)
	)
	let rects = e.rects(forRubyGroupContaining: 0)
	#expect(!rects.isEmpty && rects.allSatisfy { $0.width > 0 && $0.height > 0 })
	#expect(e.anchorRect(forRubyGroupContaining: 0) != .null)
	let r = rects[0]
	#expect(e.rubyGroup(at: CGPoint(x: r.midX, y: r.midY))?.base == NSRange(location: 0, length: 2))
}
