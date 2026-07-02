import Testing
import Foundation
import CoreText
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
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

// MARK: - Serialize

@Test func serializeOmitsBaseMarkForAutoDetectableKanjiBase() {
	// Minimal form: a pure-kanji base auto-detects, so no ｜ (matches how authors write).
	let s = PorticoRuby.parse("漢字《かんじ》")
	#expect(PorticoRuby.serialize(s) == "漢字《かんじ》")
}

@Test func serializeKeepsBaseMarkForNonKanjiBase() {
	// Auto-detection only finds kanji runs, so a non-kanji base needs the explicit ｜.
	let s = PorticoRuby.parse("｜Portico《ポルティコ》")
	#expect(PorticoRuby.serialize(s) == "｜Portico《ポルティコ》")
}

@Test func serializeKeepsBaseMarkWhenPlainKanjiPrecedesTheBase() {
	// 東 is plain; ruby is only on 京都. Without ｜, auto-detect would swallow 東 into the base,
	// so the mark must stay — decided by the self-verifying re-parse, not a hand rule.
	let s = PorticoRuby.parse("東｜京都《きょうと》")
	#expect(PorticoRuby.serialize(s) == "東｜京都《きょうと》")
}

@Test func serializeOmitsBaseMarkForKanjiBaseAfterKana() {
	// Plain kana before a kanji base doesn't get absorbed, so no ｜ (the common author form).
	let s = PorticoRuby.parse("は猫《ねこ》")
	#expect(PorticoRuby.serialize(s) == "は猫《ねこ》")
}

@Test func serializeOmitsBaseMarkForIterationMark() {
	// 々 counts as kanji for auto-detection, so 人々 needs no ｜.
	let s = PorticoRuby.parse("人々《ひとびと》")
	#expect(PorticoRuby.serialize(s) == "人々《ひとびと》")
}

@Test func serializeLeavesPlainTextUntouched() {
	let s = PorticoRuby.parse("ふつうの文。no ruby.")
	#expect(PorticoRuby.serialize(s) == "ふつうの文。no ruby.")
}

@Test func serializeHandlesMultipleAndAdjacentGroups() {
	// Back-to-back kanji groups need no ｜: the first group's 》 floors the second's auto-scan.
	let s = PorticoRuby.parse("東京《とうきょう》大学《だいがく》へ")
	#expect(PorticoRuby.serialize(s) == "東京《とうきょう》大学《だいがく》へ")
}

@Test func roundTripIsSemanticallyStable() {
	// parse → serialize → parse must reproduce the same body + readings.
	let inputs = [
		"吾輩《わがはい》は猫《ねこ》である",
		"｜きらきら《・》した",
		"漢字《かんじ》とplain textと時々《ときどき》",
		"no ruby at all",
	]
	for input in inputs {
		let once = PorticoRuby.parse(input)
		let twice = PorticoRuby.parse(PorticoRuby.serialize(once))
		#expect(once.string == twice.string, "body changed for \(input)")
		#expect(rubies(once).map { "\($0.base)=\($0.reading)" } == rubies(twice).map { "\($0.base)=\($0.reading)" },
			"readings changed for \(input)")
	}
}

@Test func fullSampleRoundTripsThroughMinimalSerialization() {
	// Integration net: adjacent groups + mixed plain / kana / latin exercised together, catching
	// interaction effects between groups and plain runs that the per-case tests can't.
	let sample = "吾輩《わがはい》は猫《ねこ》である。名前《なまえ》はまだ無《な》い。｜Portico《ポルティコ》は時々《ときどき》動く。"
	let once = PorticoRuby.parse(sample)
	let reparsed = PorticoRuby.parse(PorticoRuby.serialize(once))
	#expect(once.string == reparsed.string)
	#expect(rubies(once).map { "\($0.base)=\($0.reading)" } == rubies(reparsed).map { "\($0.base)=\($0.reading)" })
}

@Test func serializeIgnoresForeignValueUnderRubyKey() {
	// A non-CTRubyAnnotation value under the ruby key must not trap; emit plain.
	let m = NSMutableAttributedString(string: "漢字")
	m.addAttribute(rubyKey, value: "not an annotation" as NSString, range: NSRange(location: 0, length: 2))
	#expect(PorticoRuby.serialize(m) == "漢字")
}

@Test func serializeReparseIsIdempotent() {
	// Serializing already-explicit notation is a fixed point.
	let once = PorticoRuby.serialize(PorticoRuby.parse("漢字《かんじ》"))
	let twice = PorticoRuby.serialize(PorticoRuby.parse(once))
	#expect(once == twice)
}

// MARK: - Uniform line pitch (ruby must not make spacing デコボコ)

#if canImport(CoreGraphics)
import CoreGraphics

@Test func linePitchUniformRegardlessOfRuby() {
	// Lines alternate ruby / no-ruby; baseline-to-baseline pitch must be identical.
	let lines = ["漢字《かんじ》のある行", "ルビの無い普通の行", "また漢字《かんじ》です", "plain ascii line", "最後《さいご》の行"]
	let attr = PorticoRuby.parse(lines.joined(separator: "\n"))
	let engine = PorticoTextLayoutEngine(
		attributedString: attr,
		orientation: .horizontal,
		bounds: CGSize(width: 2000, height: 2000) // wide enough that no line wraps
	)

	// Pitch is the gap between consecutive line origins.
	let originY = engine.lineOrigins().map { $0.y }
	let gaps = zip(originY, originY.dropFirst()).map { abs($0 - $1) }

	#expect(gaps.count == lines.count - 1)
	let maxGap = gaps.max() ?? 0
	let minGap = gaps.min() ?? 0
	#expect(minGap > 0)

	// The reserved pitch flattens most of the ruby inflation. Core Text does not
	// fully contain a ruby annotation's ascent within the line box, so a small
	// residual remains (a fraction of a base line, vs. a whole ruby row unfixed).
	// Assert the residual stays well under one base line height.
	let baseLine: CGFloat = {
		let l = CTLineCreateWithAttributedString(NSAttributedString(string: "永") as CFAttributedString)
		var a: CGFloat = 0, d: CGFloat = 0, lead: CGFloat = 0
		CTLineGetTypographicBounds(l, &a, &d, &lead)
		return a + d + lead
	}()
	#expect(maxGap - minGap < baseLine * 0.5, "line pitch too uneven: \(gaps)")
}

@Test func columnPitchUniformInVertical() {
	// Vertical: the pitch is column-to-column (origin X), and must stay uniform.
	let cols = ["漢字《かんじ》のある列", "ルビの無い列", "また漢字《かんじ》です"]
	let attr = PorticoRuby.parse(cols.joined(separator: "\n"))
	let engine = PorticoTextLayoutEngine(
		attributedString: attr,
		orientation: .vertical,
		bounds: CGSize(width: 2000, height: 2000)
	)
	let originX = engine.lineOrigins().map { $0.x }
	let gaps = zip(originX, originX.dropFirst()).map { abs($0 - $1) }
	#expect(gaps.count == cols.count - 1)
	let baseLine: CGFloat = {
		let l = CTLineCreateWithAttributedString(NSAttributedString(string: "永") as CFAttributedString)
		var a: CGFloat = 0, d: CGFloat = 0, lead: CGFloat = 0
		CTLineGetTypographicBounds(l, &a, &d, &lead)
		return a + d + lead
	}()
	#expect((gaps.max() ?? 0) - (gaps.min() ?? 0) < baseLine * 0.5, "column pitch too uneven: \(gaps)")
}

@Test func callerParagraphStyleSurvivesPitchMerge() {
	// A caller's alignment must survive the engine merging in the line pitch.
	let para = NSMutableParagraphStyle()
	para.alignment = .right
	let attr = NSAttributedString(string: "短い行", attributes: [.paragraphStyle: para])
	let engine = PorticoTextLayoutEngine(
		attributedString: attr,
		orientation: .horizontal,
		bounds: CGSize(width: 1000, height: 200)
	)
	// Right-aligned, the short line's origin is pushed well to the right; if the
	// merge had clobbered the style it would sit near x≈0.
	let originX = engine.lineOrigins().first?.x ?? 0
	#expect(originX > 200, "caller paragraph alignment was lost; originX=\(originX)")
}
#endif

@Test func attributesAppliedToWholeString() {
	let key = NSAttributedString.Key("test.key")
	let s = PorticoRuby.parse("漢字《かんじ》", attributes: [key: 42])
	#expect(s.attribute(key, at: 0, effectiveRange: nil) as? Int == 42)
	#expect(s.attribute(key, at: 1, effectiveRange: nil) as? Int == 42)
}
