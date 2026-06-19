import Testing
import Foundation
import CoreText
@testable import Portico

private let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)

/// Collected ruby annotations: the base substring, its range, and the reading.
private func rubies(_ attributed: NSAttributedString) -> [(base: String, range: NSRange, reading: String)] {
	let full = attributed.string as NSString
	var result: [(String, NSRange, String)] = []
	attributed.enumerateAttribute(rubyKey, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
		guard let value = value else { return }
		let annotation = value as! CTRubyAnnotation
		let reading = CTRubyAnnotationGetTextForPosition(annotation, .before) as String? ?? ""
		result.append((full.substring(with: range), range, reading))
	}
	return result
}

@Test func parsesAutoBaseKanjiRun() {
	let s = PorticoRuby.parse("漢字《かんじ》です")
	#expect(s.string == "漢字です")
	let r = rubies(s)
	#expect(r.count == 1)
	#expect(r.first?.base == "漢字")
	#expect(r.first?.reading == "かんじ")
}

@Test func parsesExplicitBase() {
	let s = PorticoRuby.parse("｜大人《おとな》")
	#expect(s.string == "大人")
	let r = rubies(s)
	#expect(r.first?.base == "大人")
	#expect(r.first?.reading == "おとな")
}

@Test func explicitBaseCapturesNonKanji() {
	// Without `｜`, auto-detection would find no kanji base.
	let s = PorticoRuby.parse("｜きらきら《・》")
	#expect(s.string == "きらきら")
	#expect(rubies(s).first?.base == "きらきら")
}

@Test func autoBaseStopsAtNonKanji() {
	// Only the trailing kanji run "猫" is the base, not the leading kana.
	let s = PorticoRuby.parse("吾輩は猫《ねこ》である")
	#expect(s.string == "吾輩は猫である")
	let r = rubies(s)
	#expect(r.count == 1)
	#expect(r.first?.base == "猫")
	#expect(r.first?.reading == "ねこ")
}

@Test func multipleAnnotations() {
	let s = PorticoRuby.parse("漢字《かんじ》と仮名《かな》")
	#expect(s.string == "漢字と仮名")
	let r = rubies(s)
	#expect(r.count == 2)
	#expect(r.map(\.reading) == ["かんじ", "かな"])
}

@Test func adjacentAutoGroupsStaySeparate() {
	// The second auto base must not scan back across the first group.
	let s = PorticoRuby.parse("東京《とうきょう》大学《だいがく》")
	#expect(s.string == "東京大学")
	let r = rubies(s)
	#expect(r.count == 2)
	#expect(r.map(\.base) == ["東京", "大学"])
	#expect(r.map(\.reading) == ["とうきょう", "だいがく"])
}

@Test func unmatchedOpenAfterBaseMarkIsLiteral() {
	// `｜` then an unmatched `《`: keep the open literal and drop the dangling `｜`.
	let s = PorticoRuby.parse("｜大人《おとな")
	#expect(s.string == "大人《おとな")
	#expect(rubies(s).isEmpty)
}

@Test func iterationMarkIsKanji() {
	let s = PorticoRuby.parse("時々《ときどき》")
	#expect(s.string == "時々")
	#expect(rubies(s).first?.base == "時々")
}

// MARK: - Edge cases (spec §3.1)

@Test func emptyReadingAttachesNothing() {
	let s = PorticoRuby.parse("漢字《》")
	#expect(s.string == "漢字")
	#expect(rubies(s).isEmpty)
}

@Test func unmatchedOpenIsLiteral() {
	let s = PorticoRuby.parse("漢字《かんじ")
	#expect(s.string == "漢字《かんじ")
	#expect(rubies(s).isEmpty)
}

@Test func danglingBaseMarkIsDropped() {
	let s = PorticoRuby.parse("ABC｜DEF")
	#expect(s.string == "ABCDEF")
	#expect(rubies(s).isEmpty)
}

@Test func noBaseDiscardsReadingKeepsBody() {
	// Leading punctuation has no kanji base; reading is discarded, body kept.
	let s = PorticoRuby.parse("、《てん》")
	#expect(s.string == "、")
	#expect(rubies(s).isEmpty)
}

@Test func plainTextUnchanged() {
	let s = PorticoRuby.parse("no ruby here")
	#expect(s.string == "no ruby here")
	#expect(rubies(s).isEmpty)
}

@Test func attributesAppliedToWholeString() {
	let key = NSAttributedString.Key("test.key")
	let s = PorticoRuby.parse("漢字《かんじ》", attributes: [key: 42])
	#expect(s.attribute(key, at: 0, effectiveRange: nil) as? Int == 42)
	#expect(s.attribute(key, at: 1, effectiveRange: nil) as? Int == 42)
}
