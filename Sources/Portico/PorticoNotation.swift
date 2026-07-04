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
//  command; unknown keywords, empty payloads, unterminated commands, and
//  nested unescaped `[[` all FAIL SAFE: the tentative command re-emits as
//  literal text (content is never destroyed by malformed markup). Nesting
//  is not expressible (grammar-level refusal, matching the model's
//  precedence rule).
//

import CoreText
import Foundation

public enum PorticoNotation {

	// MARK: - Serialize

	/// Encode `attributed` to notation. Ruby and 縦中横 OVERRIDE spans carry
	/// commands; everything else (including automatic 縦中横 groups) is
	/// plain escaped text. A 縦中横 override overlapping a ruby range is
	/// DROPPED (ruby wins — nesting is not expressible).
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
			// Ruby wins: a TCY override overlapping any ruby base is dropped.
			guard !rubyRanges.contains(where: { NSIntersectionRange($0.base, range).length > 0 })
			else { return }
			let keyword = override.kind == .combine ? "tcy" : "tcy-off"
			spans.append(Span(
				range: range,
				command: "[[\(keyword):\(escape(text.substring(with: range)))]]"))
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
				// Tentative command. Snapshot for fail-safe literal re-emit.
				let start = i
				i += 2
				// keyword up to ':'
				var keyword = ""
				while i < scalars.count, scalars[i] != ":" {
					// keywords are plain ASCII identifiers; anything weird
					// (incl. '[', ']', '\\', '|') = malformed
					let k = scalars[i]
					if k.isLetter || k == "-" { keyword.append(k); i += 1 } else { break }
				}
				let knownRuby = keyword == "ruby"
				let knownTCY = keyword == "tcy" || keyword == "tcy-off"
				guard (knownRuby || knownTCY), i < scalars.count, scalars[i] == ":" else {
					// fail safe: literal "[["
					plain.append("[["); i = start + 2
					continue
				}
				i += 1 // past ':'
				// payload until unescaped "]]"; unescaped "[[" inside = malformed
				var payload = ""
				var pipeOffset: Int? = nil
				var terminated = false
				var malformed = false
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
						malformed = true; break // nesting refused
					}
					if p == "|", pipeOffset == nil {
						pipeOffset = (payload as NSString).length
						payload.append(p); i += 1
						continue
					}
					payload.append(p); i += 1
				}
				let ns = payload as NSString
				let valid: Bool
				if malformed || !terminated {
					valid = false
				} else if knownRuby {
					// base|reading, both non-empty
					if let pipe = pipeOffset, pipe > 0, pipe + 1 < ns.length { valid = true }
					else { valid = false }
				} else {
					valid = ns.length > 0 && pipeOffset == nil
				}
				guard valid else {
					// fail safe: the whole tentative command re-emits literally
					plain.append("[["); i = start + 2
					continue
				}
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
