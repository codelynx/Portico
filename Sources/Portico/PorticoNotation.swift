//
//  PorticoNotation.swift
//  Portico
//
//  0.6.0 PR-2: THE plain-text encoding for all annotations — the owned,
//  Aozora-free grammar (design: Docs/TateChuYoko-Override-Plan.md, REV 2).
//
//      [[ruby:漢字|かんじ]]     ruby
//      [[tcy:123]]              縦中横 force-combine
//      [[tcy-off:12]]           縦中横 suppress
//      future: one keyword per annotation kind — the namespace is open.
//
//  Foundational invariant: the NSAttributedString IS the model; this file
//  is only an encoding. Automatic 縦中横 groups serialize as PLAIN TEXT
//  (automatic means automatic — only artist overrides carry notation).
//
//  ESCAPING (full spec — review entry criteria): the four metacharacters
//  `[` `]` `|` `\` are ALWAYS escaped with a backslash, in plain text and
//  payloads alike — one uniform rule, trivially round-trippable. On parse,
//  backslash + ANY character yields that character literally; a trailing
//  lone backslash is a literal backslash. An unescaped `[[` opens a
//  command; unknown keywords, empty payloads, stray pipes (a second bare
//  `|` in ruby, any bare `|` in tcy), unterminated commands, and nested
//  unescaped `[[` all FAIL SAFE: the ENTIRE tentative region — from the
//  opener through the first unescaped `]]` (or end of input) — re-emits as
//  raw literal text carrying ZERO annotations (review blocker: a malformed
//  command must never let an inner command annotate). Content is never
//  destroyed by malformed markup; a malformed opener may swallow a later
//  valid command into literal text, which is the safe direction. Nesting is
//  not expressible (grammar-level refusal, matching the model's precedence
//  rule). Newlines and non-BMP characters are NOT metacharacters — they
//  pass through text and payloads unescaped.
//

import CoreText
import Foundation

public enum PorticoNotation {

	// MARK: - Serialize

	/// Encode `attributed` to notation. Ruby and 縦中横 OVERRIDE spans carry
	/// commands; everything else (including automatic 縦中横 groups) is
	/// plain escaped text. A 縦中横 override overlapping a ruby base emits
	/// only its NON-ruby fragments (ruby wins; nesting is not expressible) —
	/// the exact `combine − ruby` algebra `effectiveGroups` derives from, so
	/// the encoding stays faithful to what the model renders (review
	/// blocker: whole-span drop lost the surviving fragments). A span wholly
	/// under ruby emits nothing.
	@MainActor
	public static func serialize(_ attributed: NSAttributedString) -> String {
		let full = NSRange(location: 0, length: attributed.length)
		let text = attributed.string as NSString

		struct Span { let range: NSRange; let command: String }
		var spans: [Span] = []

		let rubyRanges = PorticoRuby.rubyGroups(in: full, of: attributed)
		for group in rubyRanges {
			spans.append(Span(
				range: group.base,
				command: "[[ruby:\(escape(text.substring(with: group.base)))|\(escape(group.reading))]]"))
		}
		attributed.enumerateAttribute(PorticoTateChuYoko.overrideKey, in: full) { value, range, _ in
			guard let override = value as? PorticoTateChuYoko.Override else { return }
			let keyword = override.kind == .combine ? "tcy" : "tcy-off"
			for fragment in PorticoTateChuYoko.subtract(rubyRanges.map(\.base), from: range)
			where fragment.length > 0 {
				spans.append(Span(
					range: fragment,
					command: "[[\(keyword):\(escape(text.substring(with: fragment)))]]"))
			}
		}
		spans.sort { $0.range.location < $1.range.location }

		var result = ""
		var cursor = 0
		for span in spans {
			if span.range.location > cursor {
				result += escape(text.substring(
					with: NSRange(location: cursor, length: span.range.location - cursor)))
			}
			result += span.command
			cursor = NSMaxRange(span.range)
		}
		if cursor < text.length {
			result += escape(text.substring(
				with: NSRange(location: cursor, length: text.length - cursor)))
		}
		return result
	}

	/// The uniform escape: every metacharacter gets a backslash.
	static func escape(_ text: String) -> String {
		var out = ""
		out.reserveCapacity(text.count)
		for character in text {
			if character == "\\" || character == "[" || character == "]" || character == "|" {
				out.append("\\")
			}
			out.append(character)
		}
		return out
	}

	// MARK: - Parse

	/// Decode notation into an attributed string carrying `attributes` as
	/// the base, ruby annotations, and identity-boxed 縦中横 overrides (one
	/// fresh box per command — adjacent commands stay distinct runs).
	@MainActor
	public static func parse(
		_ notation: String,
		attributes: [NSAttributedString.Key: Any] = [:]
	) -> NSAttributedString {
		let result = NSMutableAttributedString()
		struct Annotation { let range: NSRange; let apply: (NSMutableAttributedString, NSRange) -> Void }
		var annotations: [Annotation] = []

		var plain = "" // decoded text accumulated so far (NSString-length semantics)
		func flushLength() -> Int { (plain as NSString).length }

		let scalars = Array(notation) // Character-wise scan; escapes are char-level
		var i = 0


		while i < scalars.count {
			let c = scalars[i]
			if c == "\\" {
				if i + 1 < scalars.count { plain.append(scalars[i + 1]); i += 2 }
				else { plain.append("\\"); i += 1 }
				continue
			}
			if c == "[", i + 1 < scalars.count, scalars[i + 1] == "[" {
				// Tentative command: scan the WHOLE region first (keyword,
				// colon, payload, terminator), validate after. On ANY
				// failure the ENTIRE region — opener through the first
				// unescaped "]]", or end of input — re-emits as RAW literal
				// text with zero annotations (review blocker: recovering at
				// start+2 let an inner command annotate from inside a
				// malformed one).
				let start = i
				i += 2
				var keyword = ""
				while i < scalars.count, scalars[i].isLetter || scalars[i] == "-" {
					keyword.append(scalars[i]); i += 1
				}
				let hasColon = i < scalars.count && scalars[i] == ":"
				if hasColon { i += 1 }
				var malformed = !hasColon
					|| !(keyword == "ruby" || keyword == "tcy" || keyword == "tcy-off")
				// payload until unescaped "]]"; nesting and stray pipes mark
				// malformed but scanning CONTINUES to the terminator so the
				// whole region is known.
				var payload = ""
				var pipeOffset: Int? = nil
				var terminated = false
				while i < scalars.count {
					let p = scalars[i]
					if p == "\\" {
						if i + 1 < scalars.count { payload.append(scalars[i + 1]); i += 2 }
						else { payload.append("\\"); i += 1 }
						continue
					}
					if p == "]", i + 1 < scalars.count, scalars[i + 1] == "]" {
						terminated = true; i += 2; break
					}
					if p == "[", i + 1 < scalars.count, scalars[i + 1] == "[" {
						malformed = true // nesting refused
						payload.append("[["); i += 2
						continue
					}
					if p == "|" {
						if pipeOffset == nil { pipeOffset = (payload as NSString).length }
						else { malformed = true } // a second bare pipe is malformed
						payload.append(p); i += 1
						continue
					}
					payload.append(p); i += 1
				}
				let ns = payload as NSString
				let valid: Bool
				if malformed || !terminated {
					valid = false
				} else if keyword == "ruby" {
					// base|reading, both non-empty
					if let pipe = pipeOffset, pipe > 0, pipe + 1 < ns.length { valid = true }
					else { valid = false }
				} else {
					valid = ns.length > 0 && pipeOffset == nil
				}
				guard valid else {
					// fail safe: the whole tentative region re-emits RAW
					// (backslashes as typed — visible, recoverable).
					plain.append(contentsOf: scalars[start..<i])
					continue
				}
				let knownRuby = keyword == "ruby"
				if knownRuby {
					let pipe = pipeOffset!
					let base = ns.substring(to: pipe)
					let reading = ns.substring(from: pipe + 1)
					let location = flushLength()
					plain += base
					annotations.append(Annotation(
						range: NSRange(location: location, length: (base as NSString).length),
						apply: { string, range in
							PorticoRuby.setRuby(reading, for: range, in: string)
						}))
				} else {
					let kind: PorticoTateChuYoko.Override.Kind =
						keyword == "tcy" ? .combine : .suppress
					let location = flushLength()
					plain += payload
					annotations.append(Annotation(
						range: NSRange(location: location, length: ns.length),
						apply: { string, range in
							// fresh box per command: identity-distinct runs
							string.addAttribute(
								PorticoTateChuYoko.overrideKey,
								value: PorticoTateChuYoko.Override(kind),
								range: range)
						}))
				}
				continue
			}
			plain.append(c); i += 1
		}

		result.append(NSAttributedString(string: plain, attributes: attributes))
		for annotation in annotations {
			annotation.apply(result, annotation.range)
		}
		return result
	}

	// MARK: - Aozora (quarantined one-way importer)

	/// Import Aozora-notation text (`漢字《かんじ》` / `｜base《reading》`) —
	/// the EXPLICITLY-NAMED legacy entry point (review-unanimous): the
	/// default `parse` is a clean break; `《》` never round-trips (nothing
	/// serializes to it) and its no-escaping limitation stays quarantined
	/// here. One-way by design.
	@MainActor
	public static func parse(
		aozora: String,
		attributes: [NSAttributedString.Key: Any] = [:]
	) -> NSAttributedString {
		PorticoRuby.parse(aozora, attributes: attributes)
	}
}
