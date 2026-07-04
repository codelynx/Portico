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
	// The UAX-14 question, answered empirically: for a battery of contents
	// and wrap extents (down to ONE-CELL columns), every detected group's
	// cell must resolve (start/end carets in the SAME column). NU×NU and
	// the bang-pair classes prohibit intra-pair breaks — this sweep is the
	// proof for OUR pinned scope, fonts, and Core Text version. If it ever
	// fails, the plan's ungroup-and-relayout machinery becomes REQUIRED
	// (blank cells are forbidden).
	let contents = ["あ12う", "ああああ12", "12ああああ", "あ!?う", "ああ12ああ!?あ", "あああ12\nう12"]
	for content in contents {
		for extent in stride(from: CGFloat(8), through: 80, by: 4) {
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

@Test @MainActor func selectionIntersectingGroupShowsWholeCell() {
	let engine = editEngine("あ12う")
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 1, length: 2)) else {
		Issue.record("cell missing"); return
	}
	// Half-a-pair selection: the visual rect spans the WHOLE cell.
	let rects = engine.selectionRects(for: NSRange(location: 1, length: 1))
	#expect(rects.count == 1)
	if let rect = rects.first {
		#expect(abs(rect.height - cell.height) <= 1,
		        "half-group selection (\(rect)) shows the whole cell (\(cell))")
	}
	// The stored range is NOT mutated by the visual expansion.
	engine.setSelectedRange(NSRange(location: 1, length: 1))
	#expect(engine.selectionRange == NSRange(location: 1, length: 1))
}

@Test @MainActor func interiorTapSnapsToNearerBoundary() {
	let engine = editEngine("あ12う")
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 1, length: 2)) else {
		Issue.record("cell missing"); return
	}
	let columnX = cell.midX
	// Upper (leading) half → group start; lower (trailing) half → group end.
	let upper = engine.stringIndex(for: CGPoint(x: columnX, y: cell.maxY - cell.height * 0.25))
	let lower = engine.stringIndex(for: CGPoint(x: columnX, y: cell.minY + cell.height * 0.25))
	#expect(upper == 1, "leading-half tap → group start, got \(upper)")
	#expect(lower == 3, "trailing-half tap → group end, got \(lower)")
}

@Test @MainActor func doubleClickWordSelectsThePair() {
	let engine = editEngine("あ12う")
	#expect(engine.wordRange(at: 1) == NSRange(location: 1, length: 2),
	        "the digit pair is one word")
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
