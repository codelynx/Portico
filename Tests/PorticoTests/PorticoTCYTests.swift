//
//  PorticoTCYTests.swift
//  PorticoTests
//
//  縦中横 slice-4 PR-1: the pinned detection rule + the reservation's
//  empirical pins. Order mirrors risk: (1) the vertical run-delegate metric
//  mapping (cell-count measure tests — a wrong width/ascent/descent mapping
//  fails here immediately — RESULT: width IS the column advance but applies
//  PER GLYPH, so cell/length each); (2) glyph suppression (RESULT: the
//  inherent-suppression hypothesis FAILED — delegates do not stop glyph
//  drawing; the named plan-B is active: clear fill + zero stroke on marker
//  runs, and these pixel gates now pin the plan-B); (3) string-index
//  geometry before/interior/after groups (first-order risk, per plan);
//  (4) placement purity (the backing store never carries the marker);
//  (5) the detection rule matrix.
//

import Testing
import Foundation
import CoreGraphics
import CoreText
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
@testable import Portico

private let tcyFont = CTFontCreateWithName("HiraMinProN-W3" as CFString, 14, nil)

@MainActor
private func tcyEngine(_ text: String, _ orientation: PorticoLayoutOrientation = .vertical) -> PorticoTextLayoutEngine {
	let engine = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: text, attributes: [.font: tcyFont]),
		orientation: orientation, bounds: .zero)
	engine.update(bounds: engine.measuredSize())
	return engine
}

// MARK: - (1) Metric mapping: a group takes ONE column cell

@Test @MainActor func groupMeasuresAsOneCell() {
	// "あ12う" must measure like THREE cells ("あいう"), not four — the
	// delegate's advance landed on the column axis. A wrong metric mapping
	// (width vs ascent/descent swapped) fails this immediately.
	let grouped = tcyEngine("あ12う").measuredSize()
	let threeKana = tcyEngine("あいう").measuredSize()
	#expect(abs(grouped.height - threeKana.height) <= 2,
	        "vertical: あ12う (\(grouped)) ≈ あいう (\(threeKana)) — one cell per group")
	#expect(abs(grouped.width - threeKana.width) <= 2, "single column either way")
}

@Test @MainActor func groupOnlyContentMeasuresOneCell() {
	let group = tcyEngine("12").measuredSize()
	let kana = tcyEngine("あ").measuredSize()
	#expect(abs(group.height - kana.height) <= 2, "'12' (\(group)) ≈ one kana cell (\(kana))")
}

@Test @MainActor func threeDigitsAreNotGrouped() {
	// "123" is a run of three — no group, three sideways digits (their
	// natural rotated advances, NOT three em cells). Pin: it measures
	// DIFFERENTLY from three kana (which would indicate accidental cells).
	let digits = tcyEngine("あ123う").measuredSize()
	let kana = tcyEngine("あいうえお").measuredSize()
	#expect(abs(digits.height - kana.height) > 2,
	        "あ123う (\(digits)) must NOT measure like five cells (\(kana)) — no grouping")
}

@Test @MainActor func horizontalOrientationUntouched() {
	// No reservation in horizontal: "12" measures its NATURAL typographic
	// advance (computed here as the control via a bare CTLine — no vertical
	// forms, no delegates), not a distorted cell.
	let measured = tcyEngine("12", .horizontal).measuredSize()
	let line = CTLineCreateWithAttributedString(
		NSAttributedString(string: "12", attributes: [.font: tcyFont]))
	let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
	#expect(abs(measured.width - ceil(natural)) <= 1,
	        "horizontal '12' (\(measured.width)) == natural advance (\(natural)) — no reservation")
}

@Test @MainActor func trailingNewlineInterplayUnchanged() {
	let flat = tcyEngine("12").measuredSize()
	let broken = tcyEngine("12\n").measuredSize()
	#expect(broken.width > flat.width, "extra line fragment still reserves the next column")
	#expect(abs(broken.height - flat.height) <= 2)
}

@Test @MainActor func markedTextParticipates() {
	// OQ-A: composition forming "12" groups mid-composition (WYSIWYG).
	let engine = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: ""),
		orientation: .vertical, bounds: .zero)
	engine.typingAttributes = [.font: tcyFont]
	engine.setMarkedText("12", selectedRange: NSRange(location: 2, length: 0), replacementRange: nil)
	let marked = engine.measuredSize()
	let kana = tcyEngine("あ").measuredSize()
	#expect(abs(marked.height - kana.height) <= 2,
	        "marked '12' (\(marked)) measures one cell (\(kana)) — participation")
}

// MARK: - (2) Glyph suppression: delegate runs draw NOTHING (no post-pass yet)

@MainActor
private func inkPixelCount(_ engine: PorticoTextLayoutEngine) -> Int {
	let size = engine.bounds
	let width = max(Int(size.width.rounded(.up)), 1)
	let height = max(Int(size.height.rounded(.up)), 1)
	let context = CGContext(
		data: nil, width: width, height: height, bitsPerComponent: 8,
		bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	engine.drawText(in: context)
	guard let data = context.data else { return 0 }
	let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
	var inked = 0
	for pixel in 0..<(width * height) where buffer[pixel * 4 + 3] > 0 { inked += 1 }
	return inked
}

@Test @MainActor func originalGlyphsSuppressedUnderMiniLine() {
	// THE suppression pin, end-state form. Day-one RESULT: the inherent-
	// suppression hypothesis FAILED (CT still draws original glyphs under a
	// run delegate — attachments only look suppressed because U+FFFC's glyph
	// is blank); the named plan-B is ACTIVE (clear fill on group ranges,
	// zero stroke on the stroke frame — layout copies only). With PR-2's
	// mini-line painting, suppression is pinned by ink QUANTITY: the
	// vertical group's ink ≈ the same pair drawn horizontally (the upright
	// mini-line alone) — rotated originals underneath would add ink.
	let vertical = inkPixelCount(tcyEngine("12"))
	let horizontal = inkPixelCount(tcyEngine("12", .horizontal))
	#expect(vertical > 0, "the mini-line paints")
	#expect(abs(vertical - horizontal) < horizontal / 2,
	        "vertical (\(vertical) px) ≈ upright pair alone (\(horizontal) px) — no doubled originals")
}

@Test @MainActor func strokeFrameSuppressedToo() {
	// Outlined group: the stroke frame zeroes stroke width + clears color on
	// marker runs (plan-B's stroke half) — so outlined ink ≈ the outlined
	// upright pair alone, no phantom rotated outlines underneath.
	func outlined(_ orientation: PorticoLayoutOrientation) -> Int {
		let engine = tcyEngine("12", orientation)
		engine.outline = PorticoTextOutline(width: 2, color: CGColor(gray: 0, alpha: 1))
		return inkPixelCount(engine)
	}
	let vertical = outlined(.vertical)
	let horizontal = outlined(.horizontal)
	#expect(vertical > 0)
	#expect(abs(vertical - horizontal) < horizontal / 2,
	        "outlined vertical (\(vertical) px) ≈ outlined pair alone (\(horizontal) px)")
}

// MARK: - (3) String-index geometry (first-order risk)

@Test @MainActor func caretGeometryAroundGroup() {
	// "あ12う" vertical, indices 0(before あ) 1(before group) 3(after group)
	// 4(after う): all valid, monotonic down the column, and the group
	// boundary gap (1→3) spans ≈ one cell.
	let engine = tcyEngine("あ12う")
	let rects = [0, 1, 3, 4].map { engine.caretRect(for: $0) }
	for (i, rect) in rects.enumerated() {
		#expect(rect != .zero, "caret rect at index \([0,1,3,4][i]) exists")
	}
	// CT bottom-left coords: down the column = decreasing y.
	#expect(rects[0].midY > rects[1].midY, "index 0 above index 1")
	#expect(rects[1].midY > rects[2].midY, "group start above group end")
	#expect(rects[2].midY > rects[3].midY, "index 3 above index 4")
	let cellSpan = rects[1].midY - rects[2].midY
	#expect(abs(cellSpan - 14) <= 4, "the 1→3 gap spans ≈ one 14pt cell, got \(cellSpan)")

	// Interior index 2: sane (within the group's span, not wild).
	let interior = engine.caretRect(for: 2)
	#expect(interior.midY <= rects[1].midY + 2 && interior.midY >= rects[2].midY - 2,
	        "interior caret (\(interior.midY)) lies within the cell span [\(rects[2].midY), \(rects[1].midY)]")
}

@Test @MainActor func visibleRangeIncludesGroupCharacters() {
	// The delegate run still COVERS its two characters — nothing truncated.
	let engine = tcyEngine("あ12う")
	#expect(engine.visibleStringRangeLength() == 4, "all four characters laid out")
}

// MARK: - (4) Placement purity

@Test @MainActor func backingStoreNeverCarriesMarkerOrDelegate() {
	let engine = tcyEngine("あ12")
	engine.cursorIndex = 3
	engine.insertText("う") // typing after the group inherits from the BACKING store
	var found = false
	let full = NSRange(location: 0, length: engine.attributedString.length)
	engine.attributedString.enumerateAttributes(in: full) { attributes, _, _ in
		if attributes[PorticoTateChuYoko.groupKey] != nil { found = true }
		if attributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] != nil { found = true }
	}
	#expect(!found, "marker/delegate live on the layout COPY only — the backing store is clean")
}

// MARK: - (5) Detection rule matrix

@Test @MainActor func detectionRuleMatrix() {
	func ranges(_ text: String) -> [NSRange] { PorticoTateChuYoko.groups(in: text) }

	#expect(ranges("12") == [NSRange(location: 0, length: 2)])
	#expect(ranges("123").isEmpty, "run of three digits — no group")
	#expect(ranges("1").isEmpty, "single digit — no group")
	#expect(ranges("1234").isEmpty)
	#expect(ranges("あ12う") == [NSRange(location: 1, length: 2)])
	#expect(ranges("12月34日") == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
	#expect(ranges("!?") == [NSRange(location: 0, length: 2)])
	#expect(ranges("!!") == [NSRange(location: 0, length: 2)])
	#expect(ranges("?!") == [NSRange(location: 0, length: 2)])
	#expect(ranges("!!!").isEmpty, "isolated-run rule: three bangs do not group")
	#expect(ranges("?!?!").isEmpty, "run of four — no greedy pairing")
	#expect(ranges("１２").isEmpty, "full-width digits render upright natively — excluded")
	#expect(ranges("！？").isEmpty, "full-width bangs excluded")
	#expect(ranges("‼").isEmpty, "single-codepoint cluster excluded")
	#expect(ranges("1!").isEmpty, "digit+bang are different runs of one each")
	#expect(ranges("a12b") == [NSRange(location: 1, length: 2)], "Latin neighbors don't block digit groups")
	#expect(ranges("12!?あ") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])

	// Exclusion (ruby wins): a group intersecting an excluded range drops.
	#expect(PorticoTateChuYoko.groups(
		in: "あ12う", excluding: [NSRange(location: 1, length: 2)]).isEmpty)
	#expect(PorticoTateChuYoko.groups(
		in: "あ12う", excluding: [NSRange(location: 2, length: 1)]).isEmpty, "partial overlap drops too")
	#expect(PorticoTateChuYoko.groups(
		in: "あ12う", excluding: [NSRange(location: 0, length: 1)]) == [NSRange(location: 1, length: 2)],
	        "non-intersecting exclusion keeps the group")
}

@Test @MainActor func rubyAnnotatedGroupIsExcludedEndToEnd() {
	// Ruby on the digits (via Aozora notation) suppresses grouping: the
	// engine measures the digits SIDEWAYS (rotated advances), not one cell.
	let plain = tcyEngine("あ12う").measuredSize()
	let ruby = PorticoTextLayoutEngine(
		attributedString: PorticoRuby.parse("あ｜12《じゅうに》う", attributes: [.font: tcyFont]),
		orientation: .vertical, bounds: .zero).measuredSize()
	#expect(abs(ruby.height - plain.height) > 2,
	        "ruby'd digits (\(ruby)) must not measure like a grouped cell (\(plain))")
}

// MARK: - PR-2: draw + ink

@MainActor
private func inkedBBox(_ engine: PorticoTextLayoutEngine, band: ClosedRange<CGFloat>? = nil) -> CGRect {
	// Bounding box of inked pixels (optionally restricted to a vertical band
	// in TOP-DOWN pixel coords), in the bitmap's pixel space.
	let size = engine.bounds
	let width = max(Int(size.width.rounded(.up)), 1)
	let height = max(Int(size.height.rounded(.up)), 1)
	let context = CGContext(
		data: nil, width: width, height: height, bitsPerComponent: 8,
		bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	engine.drawText(in: context)
	guard let data = context.data else { return .null }
	let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
	var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
	for y in 0..<height {
		let topDownY = CGFloat(height - 1 - y) // CG bitmap row 0 = bottom
		if let band, !band.contains(topDownY) { continue }
		for x in 0..<width where buffer[(y * width + x) * 4 + 3] > 0 {
			minX = min(minX, x); maxX = max(maxX, x)
			minY = min(minY, y); maxY = max(maxY, y)
		}
	}
	guard maxX >= 0 else { return .null }
	return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

@Test @MainActor func groupPaintsUprightInsideCell() {
	// The pair paints WIDE (side-by-side upright digits), not tall (rotated
	// or stacked) — the orientation proof, plus cell containment.
	let engine = tcyEngine("12")
	let bbox = inkedBBox(engine)
	#expect(!bbox.isNull, "the mini-line paints (PR-1 left the cell empty)")
	#expect(bbox.width > bbox.height,
	        "upright pair is wider than tall, got \(bbox)")
	#expect(bbox.width <= engine.bounds.width + 1, "compressed to fit the column width")
}

@Test @MainActor func groupInkContainedInInkBounds() {
	// Group-only content: inkBounds non-null and CONTAINS every inked pixel
	// (the group-only-line trap, closed).
	let engine = tcyEngine("12")
	let ink = engine.inkBounds()
	#expect(!ink.isNull, "group-only content has non-null inkBounds")
	let bbox = inkedBBox(engine) // pixel space, top-down
	// inkBounds is bottom-left engine space; flip to compare.
	let flipped = CGRect(
		x: ink.minX, y: engine.bounds.height - ink.maxY,
		width: ink.width, height: ink.height)
	#expect(flipped.insetBy(dx: -1.5, dy: -1.5).contains(bbox),
	        "all inked pixels (\(bbox)) inside inkBounds (\(flipped))")
}

@Test @MainActor func groupInContextPaintsAtItsCell() {
	// "あ12う": the group's ink sits in the SECOND cell band (between the
	// kana), not at the column ends.
	let engine = tcyEngine("あ12う")
	let cellBand: ClosedRange<CGFloat> = 14...28 // second cell, top-down pt
	let bbox = inkedBBox(engine, band: cellBand)
	#expect(!bbox.isNull, "group ink present in its cell band")
	#expect(bbox.width > bbox.height, "and upright (wide), got \(bbox)")
}

@Test @MainActor func fuchiOutlinesTheGroup() {
	// White fill + black rim: both colors present in the cell = the stroke
	// pass reaches the mini-line (incl. the compressed default case — two
	// half-width digits naturally exceed one em, so compression is ACTIVE).
	let engine = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: "12", attributes: [
			.font: tcyFont, .foregroundColor: CGColor(gray: 1, alpha: 1),
		]),
		orientation: .vertical, bounds: .zero)
	engine.outline = PorticoTextOutline(width: 2, color: CGColor(gray: 0, alpha: 1))
	engine.update(bounds: engine.measuredSize())

	let size = engine.bounds
	let width = max(Int(size.width.rounded(.up)), 1)
	let height = max(Int(size.height.rounded(.up)), 1)
	let context = CGContext(
		data: nil, width: width, height: height, bitsPerComponent: 8,
		bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	engine.drawText(in: context)
	let buffer = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
	var darkInk = 0, lightInk = 0
	for pixel in 0..<(width * height) where buffer[pixel * 4 + 3] > 200 {
		if buffer[pixel * 4] < 60 { darkInk += 1 }
		if buffer[pixel * 4] > 200 { lightInk += 1 }
	}
	#expect(darkInk > 0, "black rim present around the group")
	#expect(lightInk > 0, "white fill present inside the rim")
}

@Test @MainActor func inkBoundsIncludesOutlineOutset() {
	let plain = tcyEngine("12").inkBounds()
	let outlined = tcyEngine("12")
	outlined.outline = PorticoTextOutline(width: 2, color: CGColor(gray: 0, alpha: 1))
	let ink = outlined.inkBounds()
	#expect(ink.width >= plain.width + 3 && ink.height >= plain.height + 3,
	        "outline outsets the group ink (\(plain) → \(ink))")
}

// MARK: - Review-fold additions (tight ink, causal A/B, uncompressed, foreign ruby)

@Test @MainActor func inkBoundsTightAgainstPaintedPixels() {
	// Tightness on mixed content: hidden originals are sub-pixel-shrunk on
	// the layout copy, so inkBounds must hug painted pixels. If a future
	// font/CT version resurrects the hidden paths, THIS fails and names
	// the cause.
	let engine = tcyEngine("あ12う")
	let ink = engine.inkBounds()
	let flipped = CGRect(
		x: ink.minX, y: engine.bounds.height - ink.maxY,
		width: ink.width, height: ink.height)
	let bbox = inkedBBox(engine)
	#expect(flipped.insetBy(dx: -1.5, dy: -1.5).contains(bbox), "containment")
	#expect(flipped.width - bbox.width <= 4 && flipped.height - bbox.height <= 4,
	        "tightness: inkBounds (\(flipped)) hugs pixels (\(bbox))")
}

@Test @MainActor func groupOnlyInkBoundsTightNonCircular() {
	// The NON-CIRCULAR form (fold-verification round): group-only content,
	// inkBounds vs PAINTED PIXELS directly. Two sizes — this test is what
	// FALSIFIED the quantified-4pt-overreport deviation (path slack scaled
	// with font size) and motivated the sub-pixel-shrink structural fix.
	// Plain and outlined.
	for fontSize: CGFloat in [14, 36] {
		let font = CTFontCreateWithName("HiraMinProN-W3" as CFString, fontSize, nil)
		for outlined in [false, true] {
			let engine = PorticoTextLayoutEngine(
				attributedString: NSAttributedString(string: "12", attributes: [.font: font]),
				orientation: .vertical, bounds: .zero)
			if outlined {
				engine.outline = PorticoTextOutline(width: 2, color: CGColor(gray: 0, alpha: 1))
			}
			engine.update(bounds: engine.measuredSize())
			let ink = engine.inkBounds()
			let flipped = CGRect(
				x: ink.minX, y: engine.bounds.height - ink.maxY,
				width: ink.width, height: ink.height)
			let bbox = inkedBBox(engine)
			#expect(flipped.insetBy(dx: -1.5, dy: -1.5).contains(bbox),
			        "\(fontSize)pt outlined=\(outlined): containment")
			#expect(flipped.width - bbox.width <= 4 && flipped.height - bbox.height <= 4,
			        "\(fontSize)pt outlined=\(outlined): inkBounds (\(flipped)) vs pixels (\(bbox))")
		}
	}
}

@Test @MainActor func noInkOutsideMiniLineBBoxForGroupOnlyContent() {
	// Stray-ink gate: a group-only engine has NO alpha outside the reported
	// ink + slop.
	let engine = tcyEngine("12")
	let full = inkedBBox(engine)
	let ink = engine.inkBounds()
	let flipped = CGRect(
		x: ink.minX, y: engine.bounds.height - ink.maxY,
		width: ink.width, height: ink.height)
	#expect(flipped.insetBy(dx: -2, dy: -2).contains(full),
	        "every inked pixel (\(full)) within the mini-line ink (\(flipped)) — no stray originals")
}

@Test @MainActor func suppressionAttributesAreCausal() {
	// The A/B (review fold): disable the plan-B attributes via the test seam
	// and ink must increase MATERIALLY — proving the attributes do the
	// suppressing (survives font/AA drift; compares the build to itself).
	let suppressed = inkPixelCount(tcyEngine("12"))
	PorticoTateChuYoko.suppressionDisabledForTesting = true
	defer { PorticoTateChuYoko.suppressionDisabledForTesting = false }
	let unsuppressed = inkPixelCount(tcyEngine("12"))
	#expect(unsuppressed > suppressed + suppressed / 3,
	        "disabling suppression adds the originals' ink (\(suppressed) → \(unsuppressed))")
}

@Test @MainActor func bangPairRendersUncompressed() {
	// The uncompressed branch, exercised NATURALLY (review fold): half-width
	// !? advances total well under one em, so the pair renders at natural
	// width — no font-matrix compression.
	let attrs: [NSAttributedString.Key: Any] = [.font: tcyFont]
	let natural = CGFloat(CTLineGetTypographicBounds(
		CTLineCreateWithAttributedString(NSAttributedString(string: "!?", attributes: attrs)),
		nil, nil, nil))
	let mini = PorticoTateChuYoko.miniLine(
		groupText: "!?", baseAttributes: attrs, cellCross: 14, stroke: nil)
	#expect(natural <= 14, "premise: the bang pair fits the cell (\(natural))")
	#expect(abs(mini.width - natural) <= 0.5,
	        "uncompressed branch: mini width (\(mini.width)) == natural (\(natural))")
}

@Test @MainActor func digitPairCompressesToCell() {
	// The compressed branch, direct (review fold): digits exceed the cell,
	// the mini-line compresses to fit, and a HUGE cell leaves it natural.
	let attrs: [NSAttributedString.Key: Any] = [.font: tcyFont]
	let compressed = PorticoTateChuYoko.miniLine(
		groupText: "12", baseAttributes: attrs, cellCross: 14, stroke: nil)
	#expect(compressed.width <= 14.5, "compressed to the cell, got \(compressed.width)")
	let roomy = PorticoTateChuYoko.miniLine(
		groupText: "12", baseAttributes: attrs, cellCross: 1000, stroke: nil)
	let natural = CGFloat(CTLineGetTypographicBounds(
		CTLineCreateWithAttributedString(NSAttributedString(string: "12", attributes: attrs)),
		nil, nil, nil))
	#expect(abs(roomy.width - natural) <= 0.5, "roomy cell: natural width")
}

@Test @MainActor func foreignRubyValueDoesNotSuppressGrouping() {
	// Foreign (non-CTRubyAnnotation) values under the ruby key are tolerated
	// everywhere else in Portico — they must not block grouping either
	// (review fold: genuine-annotation validation parity).
	let backing = NSMutableAttributedString(
		string: "12", attributes: [.font: tcyFont])
	backing.addAttribute(PorticoRuby.rubyKey, value: "not an annotation",
	                     range: NSRange(location: 0, length: 2))
	let engine = PorticoTextLayoutEngine(
		attributedString: backing, orientation: .vertical, bounds: .zero)
	engine.update(bounds: engine.measuredSize())
	let kana = tcyEngine("あ").measuredSize()
	#expect(abs(engine.measuredSize().height - kana.height) <= 2,
	        "foreign ruby value: still ONE cell (\(engine.measuredSize()) vs \(kana)) — grouped")
}

@Test @MainActor func platformFontCompressesWithDescriptorPreserved() {
	// The host feeds PLATFORM fonts (NSFont/UIFont — toll-free CTFont-
	// bridged); compression must keep the face, not fall back (review fold).
	#if canImport(AppKit)
	let platformFont: Any = NSFont(name: "HiraMinProN-W3", size: 14)!
	#else
	let platformFont: Any = UIFont(name: "HiraMinProN-W3", size: 14)!
	#endif
	let mini = PorticoTateChuYoko.miniLine(
		groupText: "12", baseAttributes: [.font: platformFont], cellCross: 14, stroke: nil)
	#expect(mini.width <= 14.5, "platform font compresses, got \(mini.width)")
	#expect(mini.ascent > 5, "real Mincho metrics survive (ascent \(mini.ascent)) — not a fallback face")
}
