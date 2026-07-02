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
	private static let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)

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
	/// Every ruby base is emitted in the **explicit `｜` form** (`｜base《reading》`),
	/// which is unambiguous regardless of the base content, so `parse(serialize(x))`
	/// reproduces the same base text and readings. Note: v1 has no escaping, so base
	/// text containing literal `《`, `》`, or `｜` cannot round-trip (see spec §3.1);
	/// `parse` never produces such bases, so its output always round-trips.
	public static func serialize(_ attributed: NSAttributedString) -> String {
		let full = attributed.string as NSString
		var result = ""

		attributed.enumerateAttribute(rubyKey, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
			let substring = full.substring(with: range)
			// Only treat genuine CTRubyAnnotation values as ruby; emit anything else
			// (nil, or a foreign value under this key) as plain text — never trap.
			guard let value, CFGetTypeID(value as CFTypeRef) == CTRubyAnnotationGetTypeID() else {
				result += substring
				return
			}
			let annotation = value as! CTRubyAnnotation
			let reading = CTRubyAnnotationGetTextForPosition(annotation, .before) as String? ?? ""
			if reading.isEmpty {
				result += substring
			} else {
				result += "\(baseMark)\(substring)\(rubyOpen)\(reading)\(rubyClose)"
			}
		}
		return result
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
	/// Note: readings or base text containing literal Aozora markup (`《`, `》`, `｜`) are
	/// stored fine but are outside the serialize/parse round-trip guarantee until escaping
	/// exists (design §9); no validation is performed.
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
