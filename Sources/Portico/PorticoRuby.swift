import Foundation
import CoreText

/// Ruby (furigana) support for Portico.
///
/// Parses Aozora Bunko ruby notation into an `NSAttributedString` carrying
/// `CTRubyAnnotation`s, which Core Text renders automatically in both
/// horizontal (ruby above) and vertical (ruby to the right) layouts.
///
/// Notation:
/// - Auto base:     `漢字《かんじ》`  — base is the preceding run of kanji.
/// - Explicit base: `｜大人《おとな》` — base is the text after `｜`, up to `《`.
///
/// Round-trips notation ↔ attributed string via `parse` and `serialize`.
///
/// Editing primitives — `setRuby`, `rubyGroup(at:)`, `rubyGroups(in:)` — apply, edit,
/// remove, and query ruby on an attributed string (see `Docs/RubyEditing-Design.md`).
///
/// See `Docs/RubySupport.md` for the full spec.
public enum PorticoRuby {

	private static let rubyOpen: Character = "《"   // U+300A
	private static let rubyClose: Character = "》"  // U+300B
	private static let baseMark: Character = "｜"   // U+FF5C
	/// The attributed-string key holding a `CTRubyAnnotation`. Shared across the module.
	static let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)

	/// Parses Aozora ruby notation into an attributed string.
	///
	/// Ruby marks are stripped from the body; each base range receives a
	/// `CTRubyAnnotation`. The given `attributes` are applied to the whole
	/// resulting string.
	public static func parse(_ notation: String, attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
		let chars = Array(notation)

		var body = ""
		var bodyLength = 0            // UTF-16 length of `body`, for range math
		var annotations: [(range: NSRange, reading: String)] = []
		var explicitBaseStart: Int?  // set by `｜`, in UTF-16 offsets into `body`
		var autoBaseFloor = 0        // auto-detection can't scan before the last consumed ruby

		var i = 0
		while i < chars.count {
			let ch = chars[i]

			if ch == baseMark {
				explicitBaseStart = bodyLength
				i += 1
				continue
			}

			if ch == rubyOpen {
				// Collect the reading up to the closing bracket.
				var reading = ""
				var j = i + 1
				var closed = false
				while j < chars.count {
					if chars[j] == rubyClose { closed = true; break }
					reading.append(chars[j])
					j += 1
				}

				if !closed {
					// Unmatched `《` → keep it as literal body text, and drop any
					// pending `｜` so it can't poison a later valid annotation.
					body.append(ch)
					bodyLength += utf16Length(ch)
					explicitBaseStart = nil
					i += 1
					continue
				}

				let baseStart = explicitBaseStart ?? autoBaseStart(in: body, bodyLength: bodyLength, floor: autoBaseFloor)
				let baseLength = bodyLength - baseStart
				if !reading.isEmpty && baseLength > 0 {
					annotations.append((NSRange(location: baseStart, length: baseLength), reading))
				}
				// Empty reading or no base: discard the reading, keep body, strip marks.

				explicitBaseStart = nil
				autoBaseFloor = bodyLength // next auto base can't reach back past here
				i = j + 1 // skip past `》`
				continue
			}

			body.append(ch)
			bodyLength += utf16Length(ch)
			i += 1
		}

		let result = NSMutableAttributedString(string: body, attributes: attributes)
		for annotation in annotations {
			addRuby(annotation.reading, to: annotation.range, in: result)
		}
		return result
	}

	/// Serializes an attributed string back to Aozora ruby notation — the inverse
	/// of `parse`, for persistence.
	///
	/// Emitted in **minimal form**: the `｜` base mark is omitted when auto-detection would
	/// recover the exact same base (a pure-kanji base with no plain kanji absorbed), and kept
	/// only where it's needed to disambiguate. The per-group choice is made by re-parsing the
	/// candidate (`autoBaseRoundTrips`), so serialize can't drift from `parse` and
	/// `parse(serialize(x))` reproduces the same base text and readings. Note: v1 has no escaping,
	/// so base text containing literal `《`, `》`, or `｜` cannot round-trip (see spec §3.1);
	/// `parse` never produces such bases, so its output always round-trips.
	public static func serialize(_ attributed: NSAttributedString) -> String {
		let full = attributed.string as NSString
		var result = ""
		var precedingPlain = "" // plain base text since the last ruby group, for the auto-form check

		attributed.enumerateAttribute(rubyKey, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
			let substring = full.substring(with: range)
			// Only treat genuine CTRubyAnnotation values as ruby; emit anything else
			// (nil, or a foreign value under this key) as plain text — never trap.
			guard let value, CFGetTypeID(value as CFTypeRef) == CTRubyAnnotationGetTypeID() else {
				result += substring
				precedingPlain += substring
				return
			}
			let annotation = value as! CTRubyAnnotation
			let reading = CTRubyAnnotationGetTextForPosition(annotation, .before) as String? ?? ""
			if reading.isEmpty {
				result += substring
				precedingPlain += substring
				return
			}
			// Minimal notation: emit the auto-base form (no `｜`) when the parser recovers exactly
			// this base from it in its left context; otherwise fall back to the explicit `｜`.
			// Deciding by re-parsing the candidate — not a hand-written kanji rule — keeps serialize
			// in lockstep with parse, so the round-trip guarantee can't drift as auto-detection evolves.
			let mark = autoBaseRoundTrips(base: substring, reading: reading, precedingPlain: precedingPlain) ? "" : String(baseMark)
			result += "\(mark)\(substring)\(rubyOpen)\(reading)\(rubyClose)"
			precedingPlain = "" // the group's `》` is a floor: it stops the next auto base's backward scan
		}
		return result
	}

	/// True when `parse` recovers exactly `base` from the auto-base candidate
	/// `precedingPlain + base《reading》` — i.e. the explicit `｜` can be omitted. The parser is the
	/// single source of truth for auto-detection, so this never disagrees with it by construction.
	private static func autoBaseRoundTrips(base: String, reading: String, precedingPlain: String) -> Bool {
		let candidate = "\(precedingPlain)\(base)\(rubyOpen)\(reading)\(rubyClose)"
		let groups = allRubyGroups(in: parse(candidate))
		let expected = NSRange(location: (precedingPlain as NSString).length, length: (base as NSString).length)
		return groups.count == 1 && groups[0].base == expected
	}

	// MARK: - Editing primitives (Phase 3)

	/// The ruby group covering `index`, or nil. Per the design contract, `index` must be
	/// **strictly inside** a base (querying at the end boundary returns the following
	/// group, or nil). Returns the group's **full** base range and reading — coalescing
	/// across secondary-attribute run splits (e.g. styling on part of the base) via
	/// `longestEffectiveRange`, so a styled base still reports one whole group.
	public static func rubyGroup(at index: Int, in attributed: NSAttributedString) -> (base: NSRange, reading: String)? {
		guard index >= 0, index < attributed.length else { return nil }
		var range = NSRange(location: 0, length: 0)
		let full = NSRange(location: 0, length: attributed.length)
		let value = attributed.attribute(rubyKey, at: index, longestEffectiveRange: &range, in: full)
		guard let text = reading(from: value) else { return nil }
		return (range, text)
	}

	/// Ruby groups whose base **intersects** `range`, in document order, as **full**
	/// (unclipped) base ranges — a group is atomic, so a partial overlap still returns it whole.
	public static func rubyGroups(in range: NSRange, of attributed: NSAttributedString) -> [(base: NSRange, reading: String)] {
		allRubyGroups(in: attributed).filter { NSIntersectionRange($0.base, range).length > 0 }
	}

	/// Sets — or, with a nil / empty / whitespace reading, removes — the ruby over `baseRange`.
	///
	/// Overlap rule (design §5): the **full** ranges of all groups intersecting `baseRange`
	/// are cleared first, then the new reading is applied to `baseRange` — no leftover split
	/// fragments. A zero-length `baseRange` (or one out of bounds) is a no-op. A non-blank
	/// reading is stored **as given** (trimming only decides removal; kana normalization is
	/// the client's call).
	///
	/// Note: readings or base text may contain any characters (`PorticoNotation`'s uniform
	/// escaping round-trips them); the legacy Aozora path (`PorticoRuby.serialize`/`parse`)
	/// still has no escaping and remains a one-way import concern only.
	public static func setRuby(_ reading: String?, for baseRange: NSRange, in attributed: NSMutableAttributedString) {
		guard baseRange.length > 0,
			  baseRange.location >= 0,
			  baseRange.location + baseRange.length <= attributed.length else { return }

		// Clear baseRange plus the full range of every intersecting group (no fragments left).
		var clearRange = baseRange
		for group in rubyGroups(in: baseRange, of: attributed) {
			clearRange = NSUnionRange(clearRange, group.base)
		}
		attributed.removeAttribute(rubyKey, range: clearRange)

		// Apply the reading as-given, unless it's blank (nil/empty/whitespace → remove only).
		if let reading, !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			addRuby(reading, to: baseRange, in: attributed)
			// Surgery symmetry (review fold): `setTateChuYoko` clears what it
			// overlaps; ruby does the same in the other direction — a 縦中横
			// override never stays stored UNDER a ruby base (ruby wins). The
			// span's fragments outside the base survive untouched, matching
			// the `combine − ruby` algebra everywhere else.
			attributed.removeAttribute(PorticoTateChuYoko.overrideKey, range: baseRange)
		}
	}

	/// All ruby groups in document order (full base ranges + readings).
	private static func allRubyGroups(in attributed: NSAttributedString) -> [(base: NSRange, reading: String)] {
		var groups: [(NSRange, String)] = []
		attributed.enumerateAttribute(rubyKey, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
			if let text = reading(from: value) { groups.append((range, text)) }
		}
		return groups
	}

	/// The reading from a genuine `CTRubyAnnotation` value, or nil (never traps on a foreign
	/// value under the ruby key, and treats an empty reading as "no group").
	private static func reading(from value: Any?) -> String? {
		guard let value, CFGetTypeID(value as CFTypeRef) == CTRubyAnnotationGetTypeID() else { return nil }
		let annotation = value as! CTRubyAnnotation
		let text = CTRubyAnnotationGetTextForPosition(annotation, .before) as String? ?? ""
		return text.isEmpty ? nil : text
	}

	// MARK: - Inline notation conversion (Phase 3, step 5)

	private static let rubyOpenUnit: unichar = ("《" as NSString).character(at: 0)
	private static let rubyCloseUnit: unichar = ("》" as NSString).character(at: 0)
	private static let baseMarkUnit: unichar = ("｜" as NSString).character(at: 0)

	private static func isLineBreakUnit(_ u: unichar) -> Bool {
		u == 0x000A || u == 0x000D || u == 0x2028 || u == 0x2029
	}

	/// A complete inline ruby run `[｜]base《reading》`, detected at a just-typed `》`.
	public struct InlineRubyMatch: Equatable {
		/// Full range of the run in the source (incl. `｜`, `《`, `》`) — the span to replace.
		public let sourceRange: NSRange
		/// Range of the base text within the source (marks excluded).
		public let baseRange: NSRange
		/// The reading between `《` and `》`.
		public let reading: String
	}

	/// Detects a complete inline ruby run whose closing `》` is at `closeIndex`: the matching
	/// `《`, the reading, and the base — explicit `｜base`, else a trailing run of kanji before
	/// `《` (same rules as `parse`). Returns nil if there's no matching `《` on the line, or the
	/// reading or base is empty — the caller then leaves the typed text literal.
	///
	/// `isRuby(index)` reports whether the character at `index` already belongs to a ruby group.
	/// The **auto-base** scan stops at such a character, so a new inline ruby typed right after
	/// an existing group can't swallow it. The **explicit `｜`** base intentionally crosses
	/// existing groups — the user declared that base, and `setRuby` re-bases over the overlap.
	public static func inlineRubyMatch(in string: NSString, closingAt closeIndex: Int,
									   isRuby: (Int) -> Bool = { _ in false }) -> InlineRubyMatch? {
		guard closeIndex >= 0, closeIndex < string.length,
			  string.character(at: closeIndex) == rubyCloseUnit else { return nil }

		// Matching 《, scanning back on the same line; a 》 first means it's unmatched.
		var openIndex = -1
		var i = closeIndex - 1
		while i >= 0 {
			let c = string.character(at: i)
			if c == rubyOpenUnit { openIndex = i; break }
			if c == rubyCloseUnit || isLineBreakUnit(c) { return nil }
			i -= 1
		}
		guard openIndex >= 0, closeIndex - openIndex - 1 > 0 else { return nil }
		let reading = string.substring(with: NSRange(location: openIndex + 1, length: closeIndex - openIndex - 1))

		// Base: nearest explicit ｜ before 《 (not crossing a bracket/line break), else trailing kanji.
		var markIndex: Int?
		var e = openIndex - 1
		while e >= 0 {
			let c = string.character(at: e)
			if c == baseMarkUnit { markIndex = e; break }
			if c == rubyOpenUnit || c == rubyCloseUnit || isLineBreakUnit(c) { break }
			e -= 1
		}

		let baseStart: Int
		if let m = markIndex {
			baseStart = m + 1 // explicit base — spans whatever the user marked, incl. existing ruby
		} else {
			// Auto base: trailing kanji run, but stop before an existing ruby group.
			var s = openIndex
			while s - 1 >= 0, isKanjiUnit(string.character(at: s - 1)), !isRuby(s - 1) { s -= 1 }
			baseStart = s
		}
		guard baseStart < openIndex else { return nil } // empty base → leave literal

		let baseRange = NSRange(location: baseStart, length: openIndex - baseStart)
		let sourceStart = markIndex ?? baseStart
		let sourceRange = NSRange(location: sourceStart, length: closeIndex + 1 - sourceStart)
		return InlineRubyMatch(sourceRange: sourceRange, baseRange: baseRange, reading: reading)
	}

	private static func isKanjiUnit(_ unit: unichar) -> Bool {
		guard let scalar = UnicodeScalar(unit) else { return false } // surrogate half → not a standalone kanji
		return (0x4E00...0x9FFF).contains(scalar.value) || scalar.value == 0x3005
	}

	// MARK: - Internals

	/// Start offset (UTF-16) of the trailing run of kanji in `body`, not scanning
	/// back past `floor` (the end of the previously consumed ruby base).
	private static func autoBaseStart(in body: String, bodyLength: Int, floor: Int) -> Int {
		var runLength = 0
		for ch in body.reversed() {
			if bodyLength - runLength <= floor { break }
			if isKanji(ch) {
				runLength += utf16Length(ch)
			} else {
				break
			}
		}
		return bodyLength - runLength
	}

	/// Attaches a `CTRubyAnnotation` for `reading` over `range`.
	/// Defaults: center alignment, auto overhang, Core Text's default scale.
	private static func addRuby(_ reading: String, to range: NSRange, in string: NSMutableAttributedString) {
		let annotation = CTRubyAnnotationCreateWithAttributes(
			.center, .auto, .before, reading as CFString, [:] as CFDictionary
		)
		string.addAttribute(rubyKey, value: annotation, range: range)
	}

	private static func isKanji(_ ch: Character) -> Bool {
		guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first else { return false }
		// CJK Unified Ideographs + iteration mark 々 (per spec §3).
		return (0x4E00...0x9FFF).contains(scalar.value) || scalar.value == 0x3005
	}

	private static func utf16Length(_ ch: Character) -> Int {
		return String(ch).utf16.count
	}
}
