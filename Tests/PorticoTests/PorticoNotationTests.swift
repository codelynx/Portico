//
//  PorticoNotationTests.swift
//  PorticoTests
//
//  0.6.0 PR-2: the [[…]] grammar. Entry criteria order: (1) the ROUND-TRIP
//  property (serialize∘parse = identity over payloads containing every
//  metacharacter, mixed ruby+tcy — Aozora-Portico's one great property,
//  proven before anything rides on the new grammar); (2) the escaping
//  matrix; (3) fail-safe malformed handling; (4) the Aozora importer is
//  one-way and quarantined.
//

import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import Portico

@MainActor
private func semantic(_ attributed: NSAttributedString)
	-> (text: String, ruby: [String], overrides: [String]) {
	let full = NSRange(location: 0, length: attributed.length)
	let ruby = PorticoRuby.rubyGroups(in: full, of: attributed).map {
		"\($0.base.location),\($0.base.length)=\($0.reading)"
	}
	var overrides: [String] = []
	attributed.enumerateAttribute(PorticoTateChuYoko.overrideKey, in: full) { value, range, _ in
		guard let override = value as? PorticoTateChuYoko.Override else { return }
		overrides.append("\(range.location),\(range.length)=\(override.kind)")
	}
	return (attributed.string, ruby, overrides.sorted())
}

@MainActor
private func assertRoundTrip(_ attributed: NSAttributedString,
                             _ note: Comment? = nil) {
	let encoded = PorticoNotation.serialize(attributed)
	let decoded = PorticoNotation.parse(encoded)
	let a = semantic(attributed)
	let b = semantic(decoded)
	#expect(a.text == b.text, note ?? "text round-trips: \(encoded)")
	#expect(a.ruby == b.ruby, note ?? "ruby round-trips: \(encoded)")
	#expect(a.overrides == b.overrides, note ?? "overrides round-trip: \(encoded)")
}

// MARK: - (1) Round-trip property

@Test @MainActor func roundTripHandCases() {
	// plain
	assertRoundTrip(NSAttributedString(string: "あいうえお"))
	// every metacharacter in plain text
	assertRoundTrip(NSAttributedString(string: #"a[b]c|d\e[[f]]g"#))
	// ruby
	let ruby = NSMutableAttributedString(string: "漢字とかな")
	PorticoRuby.setRuby("かんじ", for: NSRange(location: 0, length: 2), in: ruby)
	assertRoundTrip(ruby)
	// ruby whose base/reading contain metacharacters
	let meta = NSMutableAttributedString(string: #"a|b]c"#)
	PorticoRuby.setRuby(#"x[y\z"#, for: NSRange(location: 0, length: 3), in: meta)
	assertRoundTrip(meta, "metacharacter ruby")
	// a pipe INSIDE a reading survives via escaping (a second BARE pipe is malformed)
	let pipeReading = NSMutableAttributedString(string: "漢字")
	PorticoRuby.setRuby("か|んじ", for: NSRange(location: 0, length: 2), in: pipeReading)
	#expect(PorticoNotation.serialize(pipeReading) == #"[[ruby:漢字|か\|んじ]]"#)
	assertRoundTrip(pipeReading, "pipe in reading")
	// overrides, both kinds, adjacent
	let tcy = NSMutableAttributedString(string: "あ1234う12え")
	tcy.addAttribute(PorticoTateChuYoko.overrideKey,
	                 value: PorticoTateChuYoko.Override(.combine),
	                 range: NSRange(location: 1, length: 2))
	tcy.addAttribute(PorticoTateChuYoko.overrideKey,
	                 value: PorticoTateChuYoko.Override(.combine),
	                 range: NSRange(location: 3, length: 2))
	tcy.addAttribute(PorticoTateChuYoko.overrideKey,
	                 value: PorticoTateChuYoko.Override(.suppress),
	                 range: NSRange(location: 6, length: 2))
	assertRoundTrip(tcy, "adjacent combines + suppress")
	// mixed ruby + tcy in one string
	let mixed = NSMutableAttributedString(string: "第123話「漢字」!?です")
	mixed.addAttribute(PorticoTateChuYoko.overrideKey,
	                   value: PorticoTateChuYoko.Override(.combine),
	                   range: NSRange(location: 1, length: 3))
	PorticoRuby.setRuby("かんじ", for: NSRange(location: 6, length: 2), in: mixed)
	assertRoundTrip(mixed, "mixed annotations")
}

@Test @MainActor func roundTripSeededPropertySweep() {
	// Deterministic pseudo-random documents over a hostile alphabet.
	var seed: UInt64 = 0x5DEECE66D
	func next(_ bound: Int) -> Int {
		seed = seed &* 6364136223846793005 &+ 1442695040888963407
		return Int(seed >> 33) % bound
	}
	// Hostile alphabet: all four metacharacters, digits, bang-family,
	// full-width lookalikes, a NEWLINE, and non-BMP surrogate pairs
	// (review fold: a sweep that never crosses a surrogate boundary
	// can't falsify the UTF-16 arithmetic).
	let alphabet = Array("あか12!?[]|\\〈〉ンab:\n𩸽🙂")
	for _ in 0..<50 {
		let length = 4 + next(12)
		var text = ""
		for _ in 0..<length { text.append(alphabet[next(alphabet.count)]) }
		let attributed = NSMutableAttributedString(string: text)
		// Character-boundary UTF-16 offsets — attribute ranges must never
		// split a surrogate pair (that state isn't constructible through
		// any Portico surgery, so the sweep doesn't build it either).
		var charStarts: [Int] = []
		var acc = 0
		for character in text { charStarts.append(acc); acc += String(character).utf16.count }
		charStarts.append(acc)
		let charCount = charStarts.count - 1
		func utf16Range(fromChar start: Int, chars: Int) -> NSRange {
			NSRange(location: charStarts[start], length: charStarts[start + chars] - charStarts[start])
		}
		// sprinkle 0-2 overrides on non-overlapping character ranges
		if charCount >= 4 {
			let len1 = 1 + next(2)
			attributed.addAttribute(PorticoTateChuYoko.overrideKey,
			                        value: PorticoTateChuYoko.Override(next(2) == 0 ? .combine : .suppress),
			                        range: utf16Range(fromChar: 0, chars: len1))
			let start2 = len1 + 1
			if start2 + 1 < charCount {
				let len2 = 1 + next(min(2, charCount - start2 - 1))
				attributed.addAttribute(PorticoTateChuYoko.overrideKey,
				                        value: PorticoTateChuYoko.Override(.combine),
				                        range: utf16Range(fromChar: start2, chars: len2))
			}
		}
		assertRoundTrip(attributed, "seeded case: \(text)")
	}
}

@Test @MainActor func adjacentCommandsParseAsDistinctRuns() {
	// The identity guarantee crosses the notation boundary: two adjacent
	// [[tcy:]] commands parse into DISTINCT identity-boxed runs.
	let parsed = PorticoNotation.parse("[[tcy:12]][[tcy:34]]")
	let (_, _, overrides) = semantic(parsed)
	#expect(overrides == ["0,2=combine", "2,2=combine"],
	        "two distinct spans, got \(overrides)")
}

// MARK: - (2) Escaping matrix

@Test @MainActor func escapingMatrix() {
	#expect(PorticoNotation.escape(#"a[b"#) == #"a\[b"#)
	#expect(PorticoNotation.escape(#"a]b"#) == #"a\]b"#)
	#expect(PorticoNotation.escape("a|b") == #"a\|b"#)
	#expect(PorticoNotation.escape(#"a\b"#) == #"a\\b"#)
	#expect(PorticoNotation.parse(#"\[\[tcy:12\]\]"#).string == "[[tcy:12]]",
	        "escaped metacharacters are literal text")
	#expect(PorticoNotation.parse(#"end\"#).string == #"end\"#,
	        "trailing lone backslash is a literal backslash")
}

// MARK: - (3) Fail-safe malformed handling (content never destroyed)

@Test @MainActor func malformedCommandsFailSafeAsLiteralText() {
	// unknown keyword
	#expect(PorticoNotation.parse("[[foo:bar]]").string == "[[foo:bar]]")
	// unterminated
	#expect(PorticoNotation.parse("[[ruby:あ|か").string == "[[ruby:あ|か")
	// empty payloads
	#expect(PorticoNotation.parse("[[tcy:]]").string == "[[tcy:]]")
	#expect(PorticoNotation.parse("[[ruby:あ|]]").string == "[[ruby:あ|]]")
	#expect(PorticoNotation.parse("[[ruby:|か]]").string == "[[ruby:|か]]")
	// tcy payload must not contain a bare pipe
	#expect(PorticoNotation.parse("[[tcy:1|2]]").string == "[[tcy:1|2]]")
	// a second bare pipe in ruby is malformed (escape a pipe to include it)
	#expect(PorticoNotation.parse("[[ruby:a|b|c]]").string == "[[ruby:a|b|c]]")
	// nesting refused: the WHOLE region re-emits literally, exactly
	#expect(PorticoNotation.parse("[[ruby:あ[[tcy:1]]|か]]").string == "[[ruby:あ[[tcy:1]]|か]]")
	// all malformed cases carry NO annotations
	for bad in ["[[foo:bar]]", "[[tcy:]]", "[[ruby:あ|]]", "[[ruby:a|b|c]]", "[[tcy:1|2]]"] {
		let (_, ruby, overrides) = semantic(PorticoNotation.parse(bad))
		#expect(ruby.isEmpty && overrides.isEmpty, "\(bad) yields no annotations")
	}
}

@Test @MainActor func malformedRegionsNeverAnnotate() {
	// Review blocker: a malformed command must never let an INNER command
	// annotate — the entire tentative region (opener through the first
	// unescaped "]]", or end of input) re-emits as raw literal text.
	for hostile in [
		"[[ruby:あ[[tcy:12]]|か]]",  // valid tcy nested in ruby payload
		"[[foo:x[[tcy:12]]",         // valid tcy nested in unknown-keyword region
		"[[tcy:12[[tcy:34]]",        // valid tcy nested in tcy
		"[[foo あ [[tcy:12]] い",    // malformed opener swallowing a later command
	] {
		let (text, ruby, overrides) = semantic(PorticoNotation.parse(hostile))
		#expect(ruby.isEmpty && overrides.isEmpty, "\(hostile) yields no annotations")
		#expect(text == hostile, "\(hostile) preserved as raw literal text")
	}
	// …and a valid command whose "]]" lies BEYOND a malformed region still
	// parses once scanning resumes after the region.
	let after = semantic(PorticoNotation.parse("[[foo:x]][[tcy:12]]"))
	#expect(after.text == "[[foo:x]]12" && after.overrides == ["9,2=combine"],
	        "recovery resumes cleanly after a terminated malformed region")
}

@Test @MainActor func overlapSerializesNonRubyFragments() {
	// Review blocker: a combine straddling a ruby base emits its surviving
	// non-ruby fragments (the same combine − ruby algebra effectiveGroups
	// renders) — never a whole-span drop.
	let string = NSMutableAttributedString(string: "1234")
	PorticoRuby.setRuby("よみ", for: NSRange(location: 0, length: 2), in: string)
	string.addAttribute(PorticoTateChuYoko.overrideKey,
	                    value: PorticoTateChuYoko.Override(.combine),
	                    range: NSRange(location: 0, length: 4)) // non-canonical, built directly
	let encoded = PorticoNotation.serialize(string)
	#expect(encoded == "[[ruby:12|よみ]][[tcy:34]]", "fragment emitted, got \(encoded)")
	// round-trips to the CANONICAL equivalent (fragment-only override)
	let (text, ruby, overrides) = semantic(PorticoNotation.parse(encoded))
	#expect(text == "1234" && ruby == ["0,2=よみ"] && overrides == ["2,2=combine"])
	// wholly ruby-covered override emits nothing
	let covered = NSMutableAttributedString(string: "12あ")
	PorticoRuby.setRuby("よみ", for: NSRange(location: 0, length: 2), in: covered)
	covered.addAttribute(PorticoTateChuYoko.overrideKey,
	                     value: PorticoTateChuYoko.Override(.suppress),
	                     range: NSRange(location: 0, length: 2))
	#expect(PorticoNotation.serialize(covered) == "[[ruby:12|よみ]]あ")
}

@Test @MainActor func newlinesAndNonBMPRoundTrip() {
	// Newlines and surrogate-pair characters are NOT metacharacters: they
	// pass through plain text and payloads unescaped, and every range stays
	// correct across surrogate pairs (UTF-16 arithmetic pin).
	assertRoundTrip(NSAttributedString(string: "あ\nい🙂𩸽"))
	let ruby = NSMutableAttributedString(string: "𩸽の刺身")
	PorticoRuby.setRuby("ほっけ", for: NSRange(location: 0, length: 2), in: ruby) // 𩸽 = 2 UTF-16 units
	assertRoundTrip(ruby, "non-BMP ruby base")
	let tcy = NSMutableAttributedString(string: "あ1\n2い")
	tcy.addAttribute(PorticoTateChuYoko.overrideKey,
	                 value: PorticoTateChuYoko.Override(.combine),
	                 range: NSRange(location: 1, length: 3))
	assertRoundTrip(tcy, "newline inside a combine payload")
}

// MARK: - (4) Aozora: quarantined, one-way

@Test @MainActor func aozoraImportIsOneWay() {
	let imported = PorticoNotation.parse(aozora: "漢字《かんじ》")
	let (text, ruby, _) = semantic(imported)
	#expect(text == "漢字" && ruby == ["0,2=かんじ"], "importer reads Aozora")
	// …but nothing ever emits 《》: the SAME content serializes to the new grammar.
	let reserialized = PorticoNotation.serialize(imported)
	#expect(reserialized == "[[ruby:漢字|かんじ]]", "one-way: got \(reserialized)")
	#expect(!reserialized.contains("《"), "《》 never round-trips")
	// and the DEFAULT parser treats Aozora as plain text (clean break).
	#expect(PorticoNotation.parse("漢字《かんじ》").string == "漢字《かんじ》")
}
