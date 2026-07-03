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
//  plus a marker attribute carrying the group text. Delegate runs produce
//  metrics and NO glyphs (Core Text draws nothing for them — the fill and
//  stroke frames alike, since both derive from the same pure layout copy),
//  so the original characters stay in the string with their UTF-16 indices
//  PRESERVED: no replacement character, no index map. The draw post-pass
//  (PR-2) paints each group as a tiny horizontal CTLine centered upright in
//  its reserved cell.
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
enum PorticoTateChuYoko {

	/// Marker on the LAYOUT copy only: value = the group's text (String),
	/// consumed by the draw post-pass. Never present on the backing store.
	static let groupKey = NSAttributedString.Key("PorticoTateChuYokoGroup")

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
		let fullRange = NSRange(location: 0, length: layoutString.length)
		var excluded: [NSRange] = []
		layoutString.enumerateAttribute(PorticoRuby.rubyKey, in: fullRange) { value, range, _ in
			if value != nil { excluded.append(range) }
		}
		let text = layoutString.string
		for group in groups(in: text, excluding: excluded) {
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
			layoutString.addAttribute(
				.foregroundColor, value: CGColor(gray: 0, alpha: 0), range: group)
		}
	}

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
