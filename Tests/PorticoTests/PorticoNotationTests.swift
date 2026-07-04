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
	let alphabet = Array(#"あか12!?[]|\〈〉ンab:"#)
	for _ in 0..<50 {
		let length = 4 + next(12)
		var text = ""
		for _ in 0..<length { text.append(alphabet[next(alphabet.count)]) }
		let attributed = NSMutableAttributedString(string: text)
		let ns = text as NSString
		// sprinkle 0-2 overrides on non-overlapping ranges
		if ns.length >= 4 {
			let r1 = NSRange(location: 0, length: 1 + next(2))
			attributed.addAttribute(PorticoTateChuYoko.overrideKey,
			                        value: PorticoTateChuYoko.Override(next(2) == 0 ? .combine : .suppress),
			                        range: r1)
			let start2 = NSMaxRange(r1) + 1
			if start2 + 1 < ns.length {
				attributed.addAttribute(PorticoTateChuYoko.overrideKey,
				                        value: PorticoTateChuYoko.Override(.combine),
				                        range: NSRange(location: start2, length: 1 + next(min(2, ns.length - start2 - 1))))
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
	// nesting refused
	#expect(PorticoNotation.parse("[[ruby:あ[[tcy:1]]|か]]").string.hasPrefix("[[ruby:あ"),
	        "outer command fails safe; inner may still parse")
	// all malformed cases carry NO annotations
	for bad in ["[[foo:bar]]", "[[tcy:]]", "[[ruby:あ|]]"] {
		let (_, ruby, overrides) = semantic(PorticoNotation.parse(bad))
		#expect(ruby.isEmpty && overrides.isEmpty, "\(bad) yields no annotations")
	}
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
