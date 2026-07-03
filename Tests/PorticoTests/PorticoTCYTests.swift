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

@Test @MainActor func delegateRunsDrawNoGlyphs() {
	// THE suppression pin. Day-one RESULT: the inherent-suppression
	// hypothesis FAILED (CT still draws the original glyphs under a run
	// delegate — attachments look suppressed only because U+FFFC's glyph is
	// blank). The named plan-B is ACTIVE (clear foreground on group ranges,
	// layout copy only) and this gate now pins IT: a group-only engine
	// paints nothing until PR-2's mini-line post-pass draws the upright pair.
	let group = tcyEngine("12")
	#expect(inkPixelCount(group) == 0, "suppressed group must draw zero pixels")

	// Harness sanity: the same pipeline DOES paint real glyphs.
	let kana = tcyEngine("あ")
	#expect(inkPixelCount(kana) > 0, "control: kana paints")
}

@Test @MainActor func strokeFrameSuppressedToo() {
	// Outlined group-only content must ALSO paint nothing — the stroke frame
	// zeroes stroke width + clears color on marker runs (plan-B's stroke
	// half; without it the phantom outlines paint).
	let engine = tcyEngine("12")
	engine.outline = PorticoTextOutline(width: 2, color: CGColor(gray: 0, alpha: 1))
	#expect(inkPixelCount(engine) == 0, "no phantom stroke outlines for delegate runs")
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
