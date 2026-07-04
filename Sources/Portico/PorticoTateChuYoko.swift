//
//  PorticoTateChuYoko.swift
//  Portico
//
//  縦中横 (tate-chū-yoko): the AUTOMATIC upright-in-vertical rule — slice 4
//  of the manga-lettering arc (MangaLoft text objects v1 ship gate; plan in
//  MangaLoft docs/plans/text-objects-v1-slice-4-plan.md, scope pinned at
//  kickoff lock).
//
//  Pinned scope: vertical orientation only; exactly-two half-width digits
//  not adjacent to another digit, and ISOLATED half-width !?-family pairs.
//  No markup, no persistence, no host API — detection is a pure function of
//  the current text, re-derived on every relayout.
//
//  Mechanism: each group gets a `CTRunDelegate` reserving ONE column cell
//  (per-glyph advance = cell/length — CT applies delegate width per glyph)
//  plus a marker attribute carrying the group text. The delegate supplies
//  METRICS ONLY — it does NOT suppress glyph drawing (PR-1 empirical pin
//  falsified that belief; attachments only look suppressed because
//  U+FFFC's glyph is blank). Suppression is the plan-B attributes: clear
//  foreground on group ranges (fill frame) and zero stroke width / clear
//  stroke color (stroke frame) — on layout copies only. The original
//  characters stay in the string with their UTF-16 indices PRESERVED: no
//  replacement character, no index map. The draw post-pass paints each
//  group as a tiny horizontal CTLine centered upright in its reserved cell.
//
//  Placement is load-bearing: reservations live in the `layoutReadyString()`
//  COPY, never the backing store — `inheritedAttributes` can't contaminate
//  typed text with a stale delegate/marker, and Aozora serialization never
//  sees them.
//

import CoreGraphics
import CoreText
import Foundation

@MainActor
public enum PorticoTateChuYoko {

	/// Marker on the LAYOUT copy only: value = the group's text (String),
	/// consumed by the draw post-pass. Never present on the backing store.
	static let groupKey = NSAttributedString.Key("PorticoTateChuYokoGroup")

	// MARK: - Per-range override (0.6.0 PR-1) — BACKING-STORE attribute

	/// Artist-intent override on the BACKING store (the attributed string IS
	/// the model — foundational invariant). `combine` forces any range
	/// upright in one cell; `suppress` excludes an auto pair. Precedence:
	/// suppress > combine > automatic; ruby beats all.
	public static let overrideKey = NSAttributedString.Key("PorticoTateChuYokoOverride")

	/// IDENTITY-boxed (review Major, load-bearing): NSAttributedString
	/// COALESCES adjacent runs with `isEqual` values — a plain enum would
	/// merge an artist's separate "12" and "34" combines into one "1234"
	/// cell. A class instance compares by identity, so each application
	/// stays a distinct run. (Ruby dodges this only by CTRubyAnnotation's
	/// accidental reference identity; here it is deliberate.)
	public final class Override {
		public enum Kind { case combine, suppress }
		public let kind: Kind
		public init(_ kind: Kind) { self.kind = kind }
	}

	// MARK: - Detection (pure)

	/// The pinned rule, pure over (text, excluded ranges): runs of half-width
	/// digits of EXACTLY two group; runs of half-width `!`/`?` of EXACTLY two
	/// group ("123" and "!!!" are runs of 3 — no grouping, no greedy pairing).
	/// Groups intersecting any excluded range (ruby — ruby wins) are dropped.
	/// Ranges are NSString (UTF-16) ranges into `text`.
	static func groups(in text: String, excluding excludedRanges: [NSRange] = []) -> [NSRange] {
		let ns = text as NSString
		let length = ns.length
		var result: [NSRange] = []
		var i = 0
		while i < length {
			let c = ns.character(at: i)
			let kind: (unichar) -> Bool
			if isHalfWidthDigit(c) {
				kind = isHalfWidthDigit
			} else if isBangFamily(c) {
				kind = isBangFamily
			} else {
				i += 1
				continue
			}
			var j = i + 1
			while j < length, kind(ns.character(at: j)) { j += 1 }
			if j - i == 2 {
				result.append(NSRange(location: i, length: 2))
			}
			i = j
		}
		guard !excludedRanges.isEmpty else { return result }
		return result.filter { group in
			!excludedRanges.contains { NSIntersectionRange($0, group).length > 0 }
		}
	}

	private static func isHalfWidthDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 } // 0-9
	private static func isBangFamily(_ c: unichar) -> Bool { c == 0x21 || c == 0x3F } // ! ?

	// MARK: - Effective groups (normalized algebra — review Major)

	/// THE one derivation every consumer reads (reservation, draw, ink,
	/// caret, selection, wordRange). Normalized (review fold):
	///   1. ruby ranges exclude first (ruby wins over everything);
	///   2. any explicit override MASKS every intersecting automatic group;
	///   3. suppress contributes no group;
	///   4. combine contributes its non-ruby fragments.
	/// GUARANTEE: sorted, non-overlapping output.
	static func effectiveGroups(in attributed: NSAttributedString) -> [NSRange] {
		let ruby = genuineRubyRanges(in: attributed)
		var combines: [NSRange] = []
		var overrideRanges: [NSRange] = []
		let full = NSRange(location: 0, length: attributed.length)
		attributed.enumerateAttribute(overrideKey, in: full) { value, range, _ in
			guard let override = value as? Override else { return }
			overrideRanges.append(range)
			if override.kind == .combine { combines.append(range) }
		}

		// 1+2: automatic groups, minus ruby, minus any override-touched group.
		var result = groups(in: attributed.string, excluding: ruby).filter { auto in
			!overrideRanges.contains { NSIntersectionRange($0, auto).length > 0 }
		}
		// 3+4: combine fragments outside ruby.
		for combine in combines {
			result.append(contentsOf: subtract(ruby, from: combine))
		}
		result.sort { $0.location < $1.location }
		// Defensive non-overlap: stored overrides are surgery-normalized, but
		// guarantee the contract regardless.
		var normalized: [NSRange] = []
		for range in result where range.length > 0 {
			if let last = normalized.last, NSMaxRange(last) > range.location { continue }
			normalized.append(range)
		}
		return normalized
	}

	/// `range` minus every range in `cuts`, as sorted fragments.
	private static func subtract(_ cuts: [NSRange], from range: NSRange) -> [NSRange] {
		var fragments = [range]
		for cut in cuts {
			var next: [NSRange] = []
			for fragment in fragments {
				let overlap = NSIntersectionRange(fragment, cut)
				guard overlap.length > 0 else { next.append(fragment); continue }
				if overlap.location > fragment.location {
					next.append(NSRange(location: fragment.location,
					                    length: overlap.location - fragment.location))
				}
				let tail = NSMaxRange(overlap)
				if tail < NSMaxRange(fragment) {
					next.append(NSRange(location: tail, length: NSMaxRange(fragment) - tail))
				}
			}
			fragments = next
		}
		return fragments
	}

	// MARK: - Reservation (layout copy only)

	/// One column cell's metrics, boxed for the run-delegate callbacks.
	///
	/// EMPIRICAL MAPPING (PR-1 pins, RESULTS): (1) the delegate's `width` IS
	/// the advance along the vertical line (correct axis hypothesis) — but it
	/// applies PER GLYPH, so a two-character group needs `cell / 2` per glyph
	/// to total one cell. Bonus: the interior string-index offset then lands
	/// at the cell MIDPOINT by construction — OQ-C's midpoint caret for free.
	/// (2) The delegate does NOT suppress glyph drawing (that belief conflated
	/// attachments' U+FFFC-is-blank with delegate behavior) — the named plan-B
	/// is ACTIVE: clear foreground on group ranges (fill frame) and zero
	/// stroke width (stroke frame, see `currentStrokeFrame`), both on layout
	/// copies only.
	private final class CellMetrics {
		let advance: CGFloat
		let crossHalf: CGFloat
		init(advance: CGFloat, crossHalf: CGFloat) {
			self.advance = advance
			self.crossHalf = crossHalf
		}
	}

	/// Detect groups in `layoutString` (ruby ranges excluded) and reserve one
	/// em cell per group via CTRunDelegate + marker. Call ONLY on the layout
	/// copy, only for vertical orientation.
	static func applyReservations(to layoutString: NSMutableAttributedString) {
		_ = genuineRubyRanges(in: layoutString) // (kept for doc-symmetry; algebra below)
		let text = layoutString.string
		for group in effectiveGroups(in: layoutString) {
			let fontSize = PorticoTextLayoutEngine.pointSize(
				ofFontAttribute: layoutString.attribute(.font, at: group.location, effectiveRange: nil))
			// PER-GLYPH advance (empirical pin 1): CT applies the delegate
			// width to EACH glyph in the range; cell/length totals one cell.
			let metrics = CellMetrics(
				advance: fontSize / CGFloat(group.length),
				crossHalf: fontSize / 2)
			layoutString.addAttribute(
				NSAttributedString.Key(kCTRunDelegateAttributeName as String),
				value: makeDelegate(metrics),
				range: group)
			layoutString.addAttribute(
				groupKey,
				value: (text as NSString).substring(with: group),
				range: group)
			// Plan-B glyph suppression (empirical pin 2 FAILED the inherent-
			// suppression hypothesis): the original glyphs still draw under a
			// delegate, so hide the FILL here; the stroke frame zeroes its
			// stroke width for group ranges (phantom outlines otherwise).
			// Layout copy only — the backing store never sees any of this.
			if !suppressionDisabledForTesting {
				layoutString.addAttribute(
					.foregroundColor, value: CGColor(gray: 0, alpha: 0), range: group)
				// Shrink the hidden originals to a SUB-PIXEL font (layout copy
				// only, AFTER the cell metrics were computed from the real
				// size): their glyph paths collapse to ~0.01pt, so the
				// ink/path unions exclude them structurally — no second
				// coordinate space, no per-run recomputation. Delegate
				// metrics are font-independent; line metrics come from the
				// delegates' cross extents.
				let hidden: CTFont
				if let value = layoutString.attribute(.font, at: group.location, effectiveRange: nil),
				   CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() {
					hidden = CTFontCreateCopyWithAttributes(value as! CTFont, 0.01, nil, nil)
				} else {
					hidden = CTFontCreateWithName("Helvetica" as CFString, 0.01, nil)
				}
				layoutString.addAttribute(.font, value: hidden, range: group)
			}
			// SAME-LENGTH stand-in normalization (PR-3 force-wrap findings,
			// three rounds): (1) a bang pair split internally under its own
			// UAX-14 classes ("!?" at 24pt); (2) an all-digit stand-in ("00")
			// welded ADJACENT groups and flanking digits into one unbreakable
			// NU run; (3) a digit-led stand-in ("0・") still welded a LEADING
			// real digit (NU×NU). The stand-in is "あ・" — [ID][NS]:
			// ideograph first (breakable from ANY left neighbor), KATAKANA
			// MIDDLE DOT second (NS: break before it prohibited → the pair
			// holds; break after it allowed → neighbors separate). Length
			// identical (indices valid), glyphs hidden sub-pixel anyway, the
			// marker carries the REAL text. Deliberately OUTSIDE the A/B
			// seam guard: the seam tests suppression, not break protection.
			// CONTRACT: the no-split guarantee holds for inline extents ≥
			// one character cell — sub-cell columns are degenerate for ALL
			// text (MangaLoft floors boxText at 2× font size).
			// Generalized for any combine length: [ID][NS][NS]… — internally
			// unbreakable, boundary-safe both sides (same classes as the pair
			// case; PR-1 re-runs the force-wrap sweep over 3+).
			layoutString.replaceCharacters(
				in: group,
				with: "あ" + String(repeating: "・", count: group.length - 1))
		}
	}

	// MARK: - Mini-line (the upright pair, PR-2)

	/// The horizontal CTLine that paints a group upright in its cell.
	/// Built from the BACKING attributes at the group (ink color, font —
	/// marked-text underline rides along for live feedback), with layout-only
	/// keys stripped. `stroke` non-nil builds the STROKE variant (fuchi
	/// parity: stroke-only percent, mirroring the base stroke frame).
	/// OQ-B compression: when the pair's natural advance exceeds the cell's
	/// cross extent, the FONT is compressed via a horizontal matrix — glyph
	/// outlines narrow but the stroke width stays absolute (the rim keeps
	/// its artist-facing thickness), and reservation metrics are untouched.
	static func miniLine(
		groupText: String,
		baseAttributes: [NSAttributedString.Key: Any],
		cellCross: CGFloat,
		stroke: PorticoTextOutline?
	) -> (line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat) {
		var attributes = baseAttributes
		attributes.removeValue(forKey: .paragraphStyle)
		attributes.removeValue(forKey: .verticalGlyphForm)
		attributes.removeValue(forKey: PorticoRuby.rubyKey)
		attributes.removeValue(forKey: groupKey)
		attributes.removeValue(forKey: NSAttributedString.Key(kCTRunDelegateAttributeName as String))

		func build(_ attrs: [NSAttributedString.Key: Any]) -> (CTLine, CGFloat, CGFloat, CGFloat) {
			let line = CTLineCreateWithAttributedString(
				NSAttributedString(string: groupText, attributes: attrs))
			var ascent: CGFloat = 0
			var descent: CGFloat = 0
			var leading: CGFloat = 0
			let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
			return (line, width, ascent, descent)
		}

		if let stroke {
			let fontSize = PorticoTextLayoutEngine.pointSize(ofFontAttribute: attributes[.font])
			let percent = (2 * stroke.width) / fontSize * 100
			attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = percent as NSNumber
			attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = stroke.color
		}

		var (line, width, ascent, descent) = build(attributes)
		if width > cellCross, width > 0 {
			// Compress the FONT, not the context — stroking compressed glyph
			// outlines keeps the rim's absolute width. Copy-with-attributes
			// preserves the full descriptor (review fold: platform fonts are
			// toll-free CTFont-bridged, and a name round-trip would drop
			// fallbacks/features); absent/foreign fonts degrade to the CT
			// default at the same size.
			let scale = cellCross / width
			var matrix = CGAffineTransform(scaleX: scale, y: 1)
			if let value = attributes[.font], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() {
				attributes[.font] = CTFontCreateCopyWithAttributes(value as! CTFont, 0, &matrix, nil)
			} else {
				let size = PorticoTextLayoutEngine.pointSize(ofFontAttribute: attributes[.font])
				attributes[.font] = CTFontCreateWithName("Helvetica" as CFString, size, &matrix)
			}
			(line, width, ascent, descent) = build(attributes)
		}
		return (line, width, ascent, descent)
	}

	/// Ranges carrying a GENUINE `CTRubyAnnotation` — foreign values under
	/// the ruby key are tolerated everywhere else in Portico and must not
	/// suppress grouping either (review fold: exclusion uses the same
	/// validation posture as the ruby code itself).
	static func genuineRubyRanges(in attributed: NSAttributedString) -> [NSRange] {
		var ranges: [NSRange] = []
		let full = NSRange(location: 0, length: attributed.length)
		attributed.enumerateAttribute(PorticoRuby.rubyKey, in: full) { value, range, _ in
			guard let value, CFGetTypeID(value as CFTypeRef) == CTRubyAnnotationGetTypeID() else { return }
			ranges.append(range)
		}
		return ranges
	}

	/// Test seam (review fold, the causal suppression A/B): when true, the
	/// plan-B suppression attributes are NOT applied — tests assert that ink
	/// increases materially, proving the attributes do the suppressing.
	/// Never set in production.
	static var suppressionDisabledForTesting = false

	private static func makeDelegate(_ metrics: CellMetrics) -> CTRunDelegate {
		var callbacks = CTRunDelegateCallbacks(
			version: kCTRunDelegateCurrentVersion,
			dealloc: { pointer in
				Unmanaged<CellMetrics>.fromOpaque(pointer).release()
			},
			getAscent: { pointer in
				Unmanaged<CellMetrics>.fromOpaque(pointer).takeUnretainedValue().crossHalf
			},
			getDescent: { pointer in
				Unmanaged<CellMetrics>.fromOpaque(pointer).takeUnretainedValue().crossHalf
			},
			getWidth: { pointer in
				Unmanaged<CellMetrics>.fromOpaque(pointer).takeUnretainedValue().advance
			}
		)
		return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(metrics).toOpaque())!
	}
}
