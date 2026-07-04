//
//  PorticoTCYEditingTests.swift
//  PorticoTests
//
//  縦中横 slice-4 PR-3: editing through groups. FIRST: the wrap-split
//  question (promoted to REQUIRED — blank cells forbidden): a force-wrap
//  sweep proves whether UAX-14 line breaking can ever split a pinned pair
//  across columns. THEN the editing matrix: transitions (form/dissolve via
//  typing, backspace, paste, undo/redo, setRuby), selection semantics
//  (whole-cell rects, interior-tap snap, word selection), and the
//  extra-line-fragment interplay.
//

import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import Portico

private let editFont = CTFontCreateWithName("HiraMinProN-W3" as CFString, 14, nil)

@MainActor
private func editEngine(_ text: String) -> PorticoTextLayoutEngine {
	let engine = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: text, attributes: [.font: editFont]),
		orientation: .vertical, bounds: .zero)
	engine.typingAttributes = [.font: editFont]
	engine.update(bounds: engine.measuredSize())
	return engine
}

@MainActor
private func relayout(_ engine: PorticoTextLayoutEngine) {
	engine.update(bounds: engine.measuredSize())
}

// MARK: - (REQUIRED FIRST) Wrap-split: unreachable for the pinned scope?

@Test @MainActor func forceWrapSweepNeverSplitsAPinnedPair() {
	// The wrap-split question, answered empirically ACROSS THREE ROUNDS:
	// (1) bang pairs split internally under their own UAX-14 classes;
	// (2) an all-digit stand-in welded ADJACENT groups + flanking digits
	// into one unbreakable NU run (split inside a group at 21/35pt);
	// (3) the boundary-safe "0・" stand-in (NU + NS dot) holds the pair
	// while allowing separation after it. This sweep — including the
	// adjacency battery — is the proof for our pinned scope, fonts, and
	// CT version. If it ever fails, ungroup-and-relayout becomes REQUIRED
	// (blank cells are forbidden).
	let contents = [
		"あ12う", "ああああ12", "12ああああ", "あ!?う", "ああ12ああ!?あ", "あああ12\nう12",
		// adjacency + flanking battery (review fold — the class-leak cases)
		"12!?", "!?12", "あ12!?う", "1!?2", "12!?34",
	]
	for content in contents {
		// The guarantee's CONTRACT floor: one character cell (14pt here) —
		// sub-cell columns are degenerate for all text, and the host floors
		// boxText at 2× font size anyway.
		for extent in stride(from: CGFloat(14), through: 80, by: 2) {
			let engine = PorticoTextLayoutEngine(
				attributedString: NSAttributedString(string: content, attributes: [.font: editFont]),
				orientation: .vertical, bounds: .zero)
			engine.update(bounds: engine.measuredSize(inlineExtent: extent))
			let groups = PorticoTateChuYoko.groups(in: content)
			for group in groups {
				#expect(engine.tateChuYokoCell(for: group) != nil,
				        "content \(content) extent \(extent): group \(group) split across columns — ungroup machinery now REQUIRED")
			}
		}
	}
}

@Test @MainActor func wrappedGroupStillPaintsNonBlank() {
	// Belt over the sweep: at a tight extent that forces the group to wrap
	// AS A UNIT to the next column, it still paints (blank forbidden).
	let engine = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: "ああ12", attributes: [.font: editFont]),
		orientation: .vertical, bounds: .zero)
	engine.update(bounds: engine.measuredSize(inlineExtent: 28)) // two cells per column
	let size = engine.bounds
	let width = max(Int(size.width.rounded(.up)), 1)
	let height = max(Int(size.height.rounded(.up)), 1)
	let context = CGContext(
		data: nil, width: width, height: height, bitsPerComponent: 8,
		bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	engine.drawText(in: context)
	let buffer = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
	var leftHalfInk = 0 // second column (leftward) carries the wrapped group
	for y in 0..<height {
		for x in 0..<(width / 2) where buffer[(y * width + x) * 4 + 3] > 0 { leftHalfInk += 1 }
	}
	#expect(leftHalfInk > 0, "the wrapped group's column paints — nonblank")
}

// MARK: - Transitions (form / dissolve)

@Test @MainActor func typingSecondDigitFormsGroupAndCaretLandsAfterCell() {
	let engine = editEngine("あ1")
	engine.cursorIndex = 2
	engine.insertText("2")
	relayout(engine)

	#expect(abs(engine.measuredSize().height - editEngine("あい").measuredSize().height) <= 2,
	        "あ + one cell — the pair formed")
	#expect(engine.cursorIndex == 3, "caret index after the group")
	let caret = engine.caretRect(for: 3)
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 1, length: 2)) else {
		Issue.record("cell missing"); return
	}
	#expect(caret.midY <= cell.minY + 2,
	        "caret (\(caret.midY)) sits BELOW the formed cell (\(cell.minY)) — not a stale pre-swap offset")
}

@Test @MainActor func typingThirdDigitDissolvesGroup() {
	let engine = editEngine("12")
	let grouped = engine.measuredSize()
	engine.cursorIndex = 2
	engine.insertText("3")
	relayout(engine)
	#expect(PorticoTateChuYoko.groups(in: engine.attributedString.string).isEmpty, "123 = no group")
	#expect(engine.measuredSize().height > grouped.height + 2, "sideways trio outgrows the cell")
}

@Test @MainActor func backspaceThroughGroupDissolvesCleanly() {
	let engine = editEngine("あ12")
	engine.cursorIndex = 3
	engine.deleteBackward()
	relayout(engine)
	#expect(engine.attributedString.string == "あ1")
	#expect(engine.cursorIndex == 2)
	#expect(PorticoTateChuYoko.groups(in: "あ1").isEmpty, "survivor is a lone sideways digit")
	engine.deleteBackward()
	relayout(engine)
	#expect(engine.attributedString.string == "あ")
}

@Test @MainActor func pasteAcrossBoundaries() {
	// "3" between 1|2 dissolves; "12" pasted next to "3" is excluded.
	let mid = editEngine("12")
	mid.setSelectedRange(NSRange(location: 1, length: 0))
	mid.insertNotation("3")
	#expect(mid.attributedString.string == "132")
	#expect(PorticoTateChuYoko.groups(in: "132").isEmpty)

	let adjacent = editEngine("3")
	adjacent.setSelectedRange(NSRange(location: 0, length: 0))
	adjacent.insertNotation("12")
	#expect(adjacent.attributedString.string == "123")
	#expect(PorticoTateChuYoko.groups(in: "123").isEmpty, "three-digit exclusion applies to the paste result")
}

@Test @MainActor func partialSelectionReplaceDissolves() {
	let engine = editEngine("あ12う")
	engine.setSelectedRange(NSRange(location: 2, length: 1)) // the "2"
	engine.insertText("34")
	relayout(engine)
	#expect(engine.attributedString.string == "あ134う")
	#expect(PorticoTateChuYoko.groups(in: "あ134う").isEmpty, "run of three — dissolved")
}

@Test @MainActor func undoRedoAcrossFormationAndDissolution() {
	let engine = editEngine("あ1")
	engine.cursorIndex = 2
	engine.insertText("2") // forms the group
	relayout(engine)
	let grouped = engine.measuredSize()

	engine.undoManager.undo()
	relayout(engine)
	#expect(engine.attributedString.string == "あ1", "undo removes the forming digit")
	#expect(PorticoTateChuYoko.groups(in: "あ1").isEmpty)

	engine.undoManager.redo()
	relayout(engine)
	#expect(engine.attributedString.string == "あ12", "redo restores it")
	#expect(abs(engine.measuredSize().height - grouped.height) <= 1, "and the cell re-forms")
}

@Test @MainActor func setRubyOverGroupDissolvesAndRemovalReforms() {
	let engine = editEngine("12")
	let grouped = engine.measuredSize()

	engine.setRuby("じゅうに", for: NSRange(location: 0, length: 2))
	relayout(engine)
	#expect(engine.measuredSize().height > grouped.height + 2,
	        "ruby wins: the annotated pair renders sideways (taller than the cell)")

	engine.setRuby(nil, for: NSRange(location: 0, length: 2))
	relayout(engine)
	#expect(abs(engine.measuredSize().height - grouped.height) <= 1,
	        "removing the ruby re-forms the group")
}

// MARK: - Selection semantics

@Test @MainActor func partialSelectionClipsCellInLocalInlineDirection() {
	// 0.6.x partial-highlight slice — SUPERSEDES the slice-4 P5 whole-cell
	// pin (selectionIntersectingGroupShowsWholeCell): half-a-pair highlights
	// were "meaningless" only while nothing could draw them; the mini-line
	// glyph offsets (built for interior carets/gap taps) can. A partially
	// covered group now clips its cell rect in the cell's LOCAL inline
	// direction (horizontal), full cell height — so the highlight edge moves
	// through the cell exactly as the stored per-character selection does.
	let engine = editEngine("あ12う")
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 1, length: 2)) else {
		Issue.record("cell missing"); return
	}
	let left = engine.selectionRects(for: NSRange(location: 1, length: 1))  // the "1"
	let right = engine.selectionRects(for: NSRange(location: 2, length: 1)) // the "2"
	#expect(left.count == 1 && right.count == 1)
	guard let l = left.first, let r = right.first else { return }
	// Full cell height, partial width — each digit's rect is a strict sub-cell.
	#expect(abs(l.height - cell.height) <= 1 && abs(r.height - cell.height) <= 1,
	        "partial rects keep the full cell height")
	#expect(l.width < cell.width - 0.5 && r.width < cell.width - 0.5,
	        "partial rects are narrower than the cell (l \(l), r \(r), cell \(cell))")
	// The two halves TILE: left ends where right begins, and together they
	// span the drawn mini-line (within the cell).
	#expect(abs(l.maxX - r.minX) <= 0.5, "halves share the interior gap edge")
	#expect(l.minX >= cell.minX - 0.5 && r.maxX <= cell.maxX + 0.5,
	        "both stay inside the cell")
	// The stored range is untouched (editing granularity stays per-character).
	engine.setSelectedRange(NSRange(location: 1, length: 1))
	#expect(engine.selectionRange == NSRange(location: 1, length: 1))
}

@Test @MainActor func fullySelectedGroupStillPaintsWholeCell() {
	let engine = editEngine("あ12う")
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 1, length: 2)) else {
		Issue.record("cell missing"); return
	}
	let rects = engine.selectionRects(for: NSRange(location: 1, length: 2))
	#expect(rects.count == 1)
	if let rect = rects.first {
		#expect(abs(rect.height - cell.height) <= 1,
		        "full-group selection (\(rect)) spans the whole cell (\(cell))")
	}
}

@Test @MainActor func selectionCrossingCellBoundaryTilesPlainPlusPartial() {
	// あ1 — a plain char plus half the cell: one plain rect (あ, column-shaped)
	// and one partial-cell rect (the 1), NOT a single merged whole-cell rect.
	let engine = editEngine("あ12う")
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 1, length: 2)) else {
		Issue.record("cell missing"); return
	}
	let rects = engine.selectionRects(for: NSRange(location: 0, length: 2))
	#expect(rects.count == 2, "plain fragment + partial cell, got \(rects)")
	// The group's contribution is narrower than the cell — the visible edge
	// sits INSIDE the cell (the per-digit movement itself is pinned by the
	// tiling assertions in partialSelectionClipsCellInLocalInlineDirection).
	let partial = rects.min { $0.width < $1.width }
	if let partial { #expect(partial.width < cell.width - 0.5) }
}

@Test @MainActor func interiorTapResolvesByMiniLineGap() {
	// 0.6.0 REV 2 (supersedes the v1 cell-half snap): the glyphs run
	// HORIZONTALLY inside the cell, so the tap's X picks the nearest
	// mini-line gap — left edge → before the group, right edge → after,
	// center → BETWEEN the digits (real-editor behavior; interior gaps
	// must be reachable for 3+-length combines).
	// EQUIVALENCE (review fold): for 2-char groups the only interior gap
	// sits at the cell's midpoint, so gap-resolution and the v1 nearer-
	// boundary snap pick the same index for every tap — the device-
	// witnessed v1 behavior (W2) is preserved, not regressed; this rewrite
	// only ADDS the interior gaps longer groups need.
	let engine = editEngine("あ12う")
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 1, length: 2)) else {
		Issue.record("cell missing"); return
	}
	let y = cell.midY
	let left = engine.stringIndex(for: CGPoint(x: cell.minX + 0.5, y: y))
	let center = engine.stringIndex(for: CGPoint(x: cell.midX, y: y))
	let right = engine.stringIndex(for: CGPoint(x: cell.maxX - 0.5, y: y))
	#expect(left == 1, "left-edge tap → group start, got \(left)")
	#expect(center == 2, "center tap → between the digits, got \(center)")
	#expect(right == 3, "right-edge tap → group end, got \(right)")
}

@Test @MainActor func doubleClickWordSelectsThePair() {
	let engine = editEngine("あ12う")
	#expect(engine.wordRange(at: 1) == NSRange(location: 1, length: 2),
	        "the digit pair is one word")
	// Bang pairs too (review fold): the system tokenizer has no useful word
	// for "!?", so the group IS the word.
	let bangs = editEngine("あ!?う")
	#expect(bangs.wordRange(at: 1) == NSRange(location: 1, length: 2),
	        "the bang pair is one word")
	#expect(bangs.wordRange(at: 2) == NSRange(location: 1, length: 2))
}

@Test @MainActor func standInNeverLeaksIntoUserVisibleStrings() {
	// The leak gate (review fold): the layout copy textually lies ("0・"
	// stand-ins) — no string-returning surface may ever show it. A document
	// whose ONLY content is a bang pair round-trips with zero stand-in
	// characters anywhere.
	let engine = editEngine("!?")
	#expect(engine.attributedString.string == "!?", "backing store")
	#expect(PorticoRuby.serialize(engine.attributedString) == "!?", "Aozora serialization")
	#expect(engine.wordRange(at: 0) == NSRange(location: 0, length: 2))
	engine.setSelectedRange(NSRange(location: 0, length: 2))
	let selected = (engine.attributedString.string as NSString)
		.substring(with: engine.selectionRange ?? NSRange())
	#expect(selected == "!?", "selection text extraction (the copy path's source)")
	#expect(!engine.attributedString.string.contains("0"), "no stand-in digits")
	#expect(!engine.attributedString.string.contains("・"), "no stand-in dots")
}

// MARK: - Extra-line-fragment interplay

@Test @MainActor func caretAfterGroupBeforeTrailingNewline() {
	// "12\n": the group fills column 1; the trailing break reserves column 2;
	// the caret at index 3 sits at the SYNTHESIZED next column head — the
	// slice-3 fragment logic and the cell coexist.
	let engine = editEngine("12\n")
	let caret = engine.caretRect(for: 3)
	#expect(caret != .zero)
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 0, length: 2)) else {
		Issue.record("cell missing"); return
	}
	#expect(caret.midX < cell.minX, "caret in the NEXT column (left of the group's)")
}

// MARK: - Interior caret shape (witness finding: strikethrough → vertical bar)

@Test @MainActor func interiorCaretIsVerticalBarBoundariesStayColumnShaped() {
	// THE shape pin the earlier midY-in-cell test was blind to: inside a
	// group the caret follows the LOCAL inline direction (taller-than-wide
	// vertical bar between the upright glyphs); boundary carets keep the
	// column shape (wider-than-tall).
	let engine = editEngine("あ12う")
	let interior = engine.caretRect(for: 2)
	#expect(interior.height > interior.width,
	        "interior caret is a VERTICAL bar, got \(interior)")
	for boundary in [1, 3] {
		let rect = engine.caretRect(for: boundary)
		#expect(rect.width > rect.height,
		        "boundary caret at \(boundary) stays column-shaped, got \(rect)")
	}
	// And it sits BETWEEN the glyphs: x strictly inside the cell, y-span
	// within the cell's vertical extent.
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 1, length: 2)) else {
		Issue.record("cell missing"); return
	}
	#expect(interior.midX > cell.minX && interior.midX < cell.maxX)
	#expect(interior.minY >= cell.minY - 1 && interior.maxY <= cell.maxY + 1)
}

@Test @MainActor func interiorCaretUsesMiniLineOffsetForAsymmetricPairs() {
	// The x-position comes from the mini-line's OWN CT offset (review form):
	// for "12" that's ≈ the visual midpoint; for "!?" (asymmetric advances)
	// it must match the mini-line's real glyph boundary, not width/2.
	let engine = editEngine("あ!?う")
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 1, length: 2)) else {
		Issue.record("cell missing"); return
	}
	let interior = engine.caretRect(for: 2)
	let attrs: [NSAttributedString.Key: Any] = [.font: editFont]
	let mini = PorticoTateChuYoko.miniLine(
		groupText: "!?", baseAttributes: attrs, cellCross: cell.width, stroke: nil)
	let expectedX = (cell.midX - mini.width / 2)
		+ CGFloat(CTLineGetOffsetForStringIndex(mini.line, 1, nil))
	#expect(abs(interior.midX - expectedX) <= 1,
	        "caret x (\(interior.midX)) == mini-line offset (\(expectedX))")
}

@Test @MainActor func columnHopsFromInteriorCaretStillCrossColumns() {
	// The review-caught movement hole: vertical L/R hops probe by COLUMN
	// PITCH now, not the caret rect's width — a 2pt interior caret must not
	// strand the cursor in its own column.
	let engine = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: "あいうえ12", attributes: [.font: editFont]),
		orientation: .vertical, bounds: .zero)
	engine.update(bounds: engine.measuredSize(inlineExtent: 42)) // 3 cells/column → 2 columns
	// Column 1: あいう; column 2: え12. Interior of the group = index 5.
	let interior = 5
	let hopped = engine.index(from: interior, moving: .right) // toward the PREVIOUS (right) column
	#expect(hopped <= 3, "right-hop from the interior lands in column 1, got \(hopped)")
	// And from a column-1 position, left lands in column 2.
	let back = engine.index(from: 1, moving: .left)
	#expect(back >= 3, "left-hop from column 1 lands in column 2, got \(back)")
}
