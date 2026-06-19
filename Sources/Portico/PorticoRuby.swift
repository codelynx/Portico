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
/// See `Docs/RubySupport.md` for the full spec. v1 is parse + render only;
/// serialization and editing semantics are deferred.
public enum PorticoRuby {

	private static let rubyOpen: Character = "《"   // U+300A
	private static let rubyClose: Character = "》"  // U+300B
	private static let baseMark: Character = "｜"   // U+FF5C

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
		let key = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
		string.addAttribute(key, value: annotation, range: range)
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
