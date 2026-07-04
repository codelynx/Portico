//
//  PorticoTCYOverrideTests.swift
//  PorticoTests
//
//  0.6.0 PR-1: the per-range override model. Priority: (1) the COALESCING
//  pin (identity-boxed value — adjacent combines stay distinct cells);
//  (2) the normalized derivation algebra (masking, suppress, ruby-wins,
//  fragments); (3) range surgery + undo + boundary non-extension;
//  (4) 3+-length behavior (measure, stand-in force-wrap sweep, interior
//  gaps); (5) combine-of-1 and ugly-long fail-safe.
//

import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import Portico

private let ovFont = CTFontCreateWithName("HiraMinProN-W3" as CFString, 14, nil)

@MainActor
private func ovEngine(_ text: String) -> PorticoTextLayoutEngine {
	let engine = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: text, attributes: [.font: ovFont]),
		orientation: .vertical, bounds: .zero)
	engine.typingAttributes = [.font: ovFont]
	engine.update(bounds: engine.measuredSize())
	return engine
}

@MainActor
private func cells(_ engine: PorticoTextLayoutEngine) -> CGFloat {
	engine.measuredSize().height / 14 // cell count approximation (14pt cells)
}

// MARK: - (1) THE coalescing pin

@Test @MainActor func adjacentCombinesStayDistinctCells() {
	// "1234": combine {0,2} and {2,2} SEPARATELY — identity-boxed values
	// must not coalesce into one four-digit cell.
	let engine = ovEngine("1234")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 2))
	engine.setTateChuYoko(.combine, for: NSRange(location: 2, length: 2))
	engine.update(bounds: engine.measuredSize())

	let groups = PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	#expect(groups == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)],
	        "two distinct cells, got \(groups)")
	#expect(abs(cells(engine) - 2) <= 0.2, "measures as TWO cells, got \(cells(engine))")
}

// MARK: - (2) Derivation algebra

@Test @MainActor func combineOfThreeMakesOneCell() {
	let engine = ovEngine("123")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 3))
	engine.update(bounds: engine.measuredSize())
	#expect(abs(cells(engine) - 1) <= 0.2, "'123' combined = one cell, got \(cells(engine))")
}

@Test @MainActor func suppressUnmakesAnAutoPair() {
	let engine = ovEngine("12")
	let combined = engine.measuredSize() // auto: one cell
	engine.setTateChuYoko(.suppress, for: NSRange(location: 0, length: 2))
	engine.update(bounds: engine.measuredSize())
	// Suppressed digits render upright at PROPORTIONAL advances (~17pt for
	// the pair vs the 14pt cell — Hiragino's upright forms with natural
	// vertical advances, measured here) — taller than the cell, but not
	// em-stacked.
	#expect(engine.measuredSize().height > combined.height + 2,
	        "suppressed pair outgrows the cell (\(engine.measuredSize()) vs \(combined))")
	#expect(PorticoTateChuYoko.effectiveGroups(in: engine.attributedString).isEmpty)
}

@Test @MainActor func overrideMasksIntersectingAutoGroup() {
	// combine over just the "1" of an auto "12": the auto pair is MASKED;
	// the combine's own fragment is the only group (no overlapping output).
	let engine = ovEngine("12")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 1))
	let groups = PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	#expect(groups == [NSRange(location: 0, length: 1)], "masked + fragment, got \(groups)")
}

@Test @MainActor func rubyBeatsCombine() {
	let engine = ovEngine("12")
	engine.setRuby("じゅうに", for: NSRange(location: 0, length: 2))
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 2))
	#expect(PorticoTateChuYoko.effectiveGroups(in: engine.attributedString).isEmpty,
	        "ruby wins — no group under an annotated range")
}

@Test @MainActor func combinePartiallyOverRubyContributesFragmentsOnly() {
	// "あ12かんじ" with ruby on かんじ… simpler: ruby on "12"'s second char
	// region is impossible mid-group; test fragment subtraction directly:
	// combine {0,4} over "1か2じ" where か carries ruby → fragments exclude it.
	let engine = ovEngine("1か23")
	engine.setRuby("か", for: NSRange(location: 1, length: 1))
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 4))
	let groups = PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	#expect(groups == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 2)],
	        "non-ruby fragments only, got \(groups)")
}

// MARK: - (3) Surgery, undo, boundaries

@Test @MainActor func surgeryReplacesIntersectingSpans() {
	let engine = ovEngine("12345")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 2))
	engine.setTateChuYoko(.combine, for: NSRange(location: 1, length: 3))
	let groups = PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	#expect(groups == [NSRange(location: 1, length: 3)],
	        "intersecting span cleared, replacement wins whole, got \(groups)")
}

@Test @MainActor func clearRemovesOverride() {
	let engine = ovEngine("123")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 3))
	engine.setTateChuYoko(nil, for: NSRange(location: 0, length: 3))
	#expect(engine.tateChuYokoOverride(at: 0) == nil)
	#expect(PorticoTateChuYoko.effectiveGroups(in: engine.attributedString).isEmpty,
	        "'123' back to automatic (no group)")
}

@Test @MainActor func undoRedoRoundTripsOverride() {
	let engine = ovEngine("123")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 3))
	#expect(engine.tateChuYokoOverride(at: 0) == .combine)
	engine.undoManager.undo()
	#expect(engine.tateChuYokoOverride(at: 0) == nil, "undo clears the application")
	engine.undoManager.redo()
	#expect(engine.tateChuYokoOverride(at: 0) == .combine, "redo restores it")
}

@Test @MainActor func noOpClearPushesNoUndoStep() {
	let engine = ovEngine("123")
	#expect(!engine.undoManager.canUndo)
	engine.setTateChuYoko(nil, for: NSRange(location: 0, length: 3))
	#expect(!engine.undoManager.canUndo, "clearing nothing is a no-op")
}

@Test @MainActor func typingAtBoundaryDoesNotExtendOverride() {
	let engine = ovEngine("12")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 2))
	engine.cursorIndex = 2
	engine.insertText("3")
	#expect(engine.tateChuYokoOverride(at: 2) == nil,
	        "typed '3' carries no override (ruby's boundary rule)")
	let groups = PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	#expect(groups == [NSRange(location: 0, length: 2)], "the cell stays a pair")
}

@Test @MainActor func typingStrictlyInsideOverrideExtendsIt() {
	// Ruby parity (review fold): insertion strictly INSIDE a span joins it —
	// same edge rule as insertionExtendsRubyGroup; the inherited box is the
	// SAME instance, so the span stays one run.
	let engine = ovEngine("12")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 2))
	engine.cursorIndex = 1
	engine.insertText("3")
	#expect(engine.tateChuYokoOverride(at: 1) == .combine,
	        "typed '3' joins the span (ruby's interior rule)")
	let groups = PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	#expect(groups == [NSRange(location: 0, length: 3)], "one 3-char cell, one run")
}

@Test @MainActor func setRubyTrimsOverrideUnderNewBase() {
	// Surgery symmetry (review fold): setTateChuYoko clears what it
	// overlaps; setRuby now does the same in the other direction — an
	// override never stays stored UNDER a ruby base. Fragments outside
	// the base survive (the combine − ruby algebra).
	let string = NSMutableAttributedString(string: "1234")
	string.addAttribute(PorticoTateChuYoko.overrideKey,
	                    value: PorticoTateChuYoko.Override(.combine),
	                    range: NSRange(location: 0, length: 4))
	PorticoRuby.setRuby("よみ", for: NSRange(location: 0, length: 2), in: string)
	#expect(string.attribute(PorticoTateChuYoko.overrideKey, at: 0, effectiveRange: nil) == nil,
	        "no override under the new ruby base")
	#expect(string.attribute(PorticoTateChuYoko.overrideKey, at: 2, effectiveRange: nil) != nil,
	        "the fragment outside the base survives")
}

// MARK: - (4) 3+ behavior

@Test @MainActor func forceWrapSweepHoldsForLongerCombines() {
	// The generalized stand-in ([ID][NS][NS]…) gets its own sweep — the
	// pair proof doesn't transfer for free (review: "doesn't ship
	// plausible"). Combine-of-3 and -4 embedded in kana, extents ≥ 1 cell.
	for (text, range) in [("あ123う", NSRange(location: 1, length: 3)),
	                       ("ああ1234あ", NSRange(location: 2, length: 4))] {
		for extent in stride(from: CGFloat(14), through: 70, by: 2) {
			let engine = PorticoTextLayoutEngine(
				attributedString: NSAttributedString(string: text, attributes: [.font: ovFont]),
				orientation: .vertical, bounds: .zero)
			engine.setTateChuYoko(.combine, for: range)
			engine.update(bounds: engine.measuredSize(inlineExtent: extent))
			#expect(engine.tateChuYokoCell(for: range) != nil,
			        "\(text) ext \(extent): combined run split across columns")
		}
	}
}

@Test @MainActor func interiorGapsReachableInLongCombine() {
	let engine = ovEngine("あ123う")
	engine.setTateChuYoko(.combine, for: NSRange(location: 1, length: 3))
	engine.update(bounds: engine.measuredSize())
	guard let cell = engine.tateChuYokoCell(for: NSRange(location: 1, length: 3)) else {
		Issue.record("cell missing"); return
	}
	// Taps across the cell's width resolve to 1,2,3,4 (all gaps).
	var seen = Set<Int>()
	for fraction in stride(from: CGFloat(0.05), through: 0.95, by: 0.1) {
		seen.insert(engine.stringIndex(
			for: CGPoint(x: cell.minX + cell.width * fraction, y: cell.midY)))
	}
	#expect(seen.contains(2) && seen.contains(3), "interior gaps reachable, got \(seen.sorted())")
	#expect(seen.min() == 1 && seen.max() == 4, "edges reach the boundaries, got \(seen.sorted())")
}

// MARK: - (5) Length extremes

@Test @MainActor func combineOfOneIsOneCell() {
	let engine = ovEngine("5")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 1))
	engine.update(bounds: engine.measuredSize())
	#expect(abs(cells(engine) - 1) <= 0.2)
}

@Test @MainActor func uglyLongCombineFailsSafely() {
	// 8 digits in one cell: compressed absurdly but ONE cell, painted,
	// contained — the artist's choice renders rather than breaking.
	let engine = ovEngine("12345678")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 8))
	engine.update(bounds: engine.measuredSize())
	#expect(abs(cells(engine) - 1) <= 0.2, "one cell, got \(cells(engine))")
	let ink = engine.inkBounds()
	#expect(!ink.isNull && ink.width <= engine.bounds.width + 1,
	        "compressed within the column, ink \(ink) in \(engine.bounds)")
}

// MARK: - (6) Clipboard + menu toggle (0.6.0 PR-3)

@Test @MainActor func copyPasteAdjacentYieldsDistinctCells() {
	// The review's paste-coalescing hazard, closed by construction: copy
	// serializes to the OWNED notation; paste parses it, minting a FRESH
	// identity box per command — pasting a combine right after itself
	// yields two distinct cells, never one welded 4-digit span.
	let engine = ovEngine("12")
	engine.setTateChuYoko(.combine, for: NSRange(location: 0, length: 2))
	engine.setSelectedRange(NSRange(location: 0, length: 2))
	let copied = engine.serializedSelection()
	#expect(copied == "[[tcy:12]]", "clipboard carries the owned grammar, got \(copied ?? "nil")")
	engine.setSelectedRange(NSRange(location: 2, length: 0)) // caret to end, selection cleared
	engine.insertNotation(copied!)
	#expect(engine.attributedString.string == "1212")
	let groups = PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	#expect(groups == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)],
	        "two distinct cells, got \(groups)")
}

@Test @MainActor func togglePinsApplyThenReleaseClears() {
	// apply on plain text → one combine span; release on a pure explicit
	// combine (4 digits — no auto group underneath) just CLEARS, storing
	// no unnecessary suppress.
	let engine = ovEngine("1234")
	#expect(engine.tateChuYokoToggle(for: NSRange(location: 0, length: 4)) == .apply)
	engine.performTateChuYokoToggle(for: NSRange(location: 0, length: 4))
	#expect(PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	        == [NSRange(location: 0, length: 4)])
	#expect(engine.tateChuYokoToggle(for: NSRange(location: 0, length: 4)) == .release)
	engine.performTateChuYokoToggle(for: NSRange(location: 0, length: 4))
	#expect(PorticoTateChuYoko.effectiveGroups(in: engine.attributedString).isEmpty)
	#expect(engine.tateChuYokoOverride(at: 0) == nil, "clearing sufficed — no suppress stored")
}

@Test @MainActor func releaseOnAutoPairSuppressesAndUndoesAsOneStep() {
	let engine = ovEngine("あ12う")
	// the auto pair renders → release must SUPPRESS (clearing changes nothing)
	#expect(engine.tateChuYokoToggle(for: NSRange(location: 1, length: 2)) == .release)
	engine.performTateChuYokoToggle(for: NSRange(location: 1, length: 2))
	#expect(PorticoTateChuYoko.effectiveGroups(in: engine.attributedString).isEmpty)
	#expect(engine.tateChuYokoOverride(at: 1) == .suppress)
	engine.undoManager.undo() // ONE step restores the pair
	#expect(PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	        == [NSRange(location: 1, length: 2)])
}

@Test @MainActor func mixedSelectionResolvesApplyWins() {
	// あ12 — the pair renders, あ doesn't → mixed → APPLY (bold-editor
	// convention), normalizing the whole selection into one span.
	let engine = ovEngine("あ12う")
	#expect(engine.tateChuYokoToggle(for: NSRange(location: 0, length: 3)) == .apply)
	engine.performTateChuYokoToggle(for: NSRange(location: 0, length: 3))
	#expect(PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	        == [NSRange(location: 0, length: 3)])
}

@Test @MainActor func applyOnSuppressedRangeRemovesSuppress() {
	// "縦中横 on a suppressed range removes the suppress" — never a
	// suppress-still-wins surprise.
	let engine = ovEngine("12")
	engine.setTateChuYoko(.suppress, for: NSRange(location: 0, length: 2))
	#expect(PorticoTateChuYoko.effectiveGroups(in: engine.attributedString).isEmpty)
	#expect(engine.tateChuYokoToggle(for: NSRange(location: 0, length: 2)) == .apply)
	engine.performTateChuYokoToggle(for: NSRange(location: 0, length: 2))
	#expect(engine.tateChuYokoOverride(at: 0) == .combine)
	#expect(PorticoTateChuYoko.effectiveGroups(in: engine.attributedString)
	        == [NSRange(location: 0, length: 2)])
}

@Test @MainActor func copySlicingThroughRubyAndOverrideStaysFaithful() {
	// Selection slicing an annotated document serializes what the slice
	// carries: the override fragment inside the selection round-trips.
	let engine = ovEngine("あ1234う")
	engine.setTateChuYoko(.combine, for: NSRange(location: 1, length: 4))
	engine.setSelectedRange(NSRange(location: 0, length: 4)) // あ123 — slices the span
	let copied = engine.serializedSelection()
	#expect(copied == "あ[[tcy:123]]", "sliced override serializes its selected part, got \(copied ?? "nil")")
}
