import Testing
import Foundation
import CoreGraphics
@testable import Portico

private func engine(_ s: String, orientation: PorticoLayoutOrientation = .horizontal) -> PorticoTextLayoutEngine {
	PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: s),
		orientation: orientation,
		bounds: CGSize(width: 2000, height: 2000) // wide/tall enough that lines don't wrap
	)
}

// MARK: - Engine selection geometry (backs iOS UITextInput.selectionRects)

@Test func selectionRectsEmptyForZeroLengthRange() {
	// A caret (zero-length) has no selection rects.
	#expect(engine("hello world").selectionRects(for: NSRange(location: 3, length: 0)).isEmpty)
}

@Test func selectionRectsSingleLineIsOneRect() {
	let rects = engine("hello world").selectionRects(for: NSRange(location: 0, length: 5))
	#expect(rects.count == 1)
	#expect(rects[0].width > 0 && rects[0].height > 0)
}

@Test func selectionRectsSpanOneRectPerLine() {
	// Selecting across three explicit lines yields one rect per line (multi-line,
	// unlike rect(forCharacterRange:) which returns only the first).
	let text = "line one\nline two\nline three"
	let rects = engine(text).selectionRects(for: NSRange(location: 0, length: (text as NSString).length))
	#expect(rects.count == 3)
	#expect(rects.allSatisfy { $0.width > 0 && $0.height > 0 })
}

@Test func selectionRectsWorkInVerticalOrientation() {
	let text = "縦書き\nテスト"
	let rects = engine(text, orientation: .vertical).selectionRects(for: NSRange(location: 0, length: (text as NSString).length))
	#expect(rects.count == 2)
	#expect(rects.allSatisfy { $0.width > 0 && $0.height > 0 })
}

// MARK: - Selection anchor consistency (external selection → Shift+Arrow)

@Test func externalSelectionThenShiftArrowExtends() {
	// Simulates UIKit setting a non-empty selection (via selectedTextRange), then a
	// Shift+Arrow. Before setSelectedRange seeded the anchor, this failed to extend.
	let e = engine("hello world")
	e.setSelectedRange(NSRange(location: 0, length: 5)) // "hello"
	#expect(e.selectionRange == NSRange(location: 0, length: 5))
	e.moveCursor(direction: .right, modifySelection: true)
	#expect(e.selectionRange == NSRange(location: 0, length: 6)) // extended, anchor at 0
}

@Test func setSelectedRangeCollapsesZeroLengthToCaret() {
	let e = engine("hello world")
	e.setSelectedRange(NSRange(location: 3, length: 0))
	#expect(e.selectionRange == nil)
	#expect(e.cursorIndex == 3)
}

@Test func drawsSelectionHighlightDefaultsOn() {
	// macOS relies on the engine drawing its own selection highlight.
	#expect(engine("x").drawsSelectionHighlight == true)
}

@Test func drawsCaretOwnsVerticalEvenWhenHighlightOff() {
	// iOS turns off the highlight (UIKit owns selection), but the engine must still own
	// the caret in vertical (UIKit can't render one) and cede it in horizontal.
	let v = engine("x", orientation: .vertical)
	v.drawsSelectionHighlight = false
	#expect(v.drawsCaret == true)
	let h = engine("x", orientation: .horizontal)
	h.drawsSelectionHighlight = false
	#expect(h.drawsCaret == false)
}

@Test func verticalCaretAtLineStartStaysInBounds() {
	// Regression: at the top of a column the caret's y equalled the bounds top, so its
	// thickness spilled above the visible area and the caret vanished. It must stay inside.
	let text = "吾輩は猫である。\nどこで生れたか。\nPortico engine."
	let h: CGFloat = 400
	let e = PorticoTextLayoutEngine(attributedString: NSAttributedString(string: text), orientation: .vertical, bounds: CGSize(width: 400, height: h))
	let ns = text as NSString
	var starts = [0]
	for i in 0..<ns.length where ns.character(at: i) == 10 { starts.append(i + 1) }
	for s in starts {
		let r = e.caretRect(for: s)
		#expect(r.maxY <= h, "caret at line-start idx \(s) spills above bounds: \(r)")
		#expect(r.minY >= 0, "caret at line-start idx \(s) spills below bounds: \(r)")
	}
}

// MARK: - Grapheme-aware deleteBackward (non-BMP / combining sequences)

@Test func deleteBackwardRemovesWholeSurrogatePair() {
	let e = engine("a𩸽") // 𩸽 = U+29E3D, a surrogate pair (2 UTF-16 units) at [1,3)
	e.cursorIndex = 3
	e.deleteBackward()
	#expect(e.attributedString.string == "a") // whole character removed, not a lone surrogate
	#expect(e.cursorIndex == 1)
}

@Test func deleteBackwardRemovesWholeCombiningSequence() {
	let e = engine("ae\u{0301}") // "aé" — e + combining acute (one grapheme, 2 units)
	e.cursorIndex = 3
	e.deleteBackward()
	#expect(e.attributedString.string == "a") // whole é removed, not just the accent
	#expect(e.cursorIndex == 1)
}

// MARK: - Word range (double-click selection)

@Test func wordRangeSelectsLatinWord() {
	let e = engine("Hello world")
	#expect(e.wordRange(at: 7) == NSRange(location: 6, length: 5)) // "world"
	#expect(e.wordRange(at: 2) == NSRange(location: 0, length: 5)) // "Hello"
}

@Test func wordRangeSegmentsJapanese() {
	let e = engine("吾輩は猫である")
	let r = e.wordRange(at: 0)
	#expect(r != nil && r!.length > 0 && NSLocationInRange(0, r!)) // a non-empty word containing 吾
}

@Test func wordRangeNilOnEmpty() {
	#expect(engine("").wordRange(at: 0) == nil)
}

// MARK: - External text replacement clamps edit state

@Test func externalShorterTextClampsCursorAndDropsSelection() {
	let e = engine("Hello world")
	e.setSelectedRange(NSRange(location: 6, length: 5)) // select "world" → cursor at 11
	e.update(attributedString: NSAttributedString(string: "Hi")) // length 2, well inside old state
	#expect(e.cursorIndex == 2)          // clamped from 11 into bounds
	#expect(e.selectionRange == nil)     // out-of-bounds selection dropped
	// A follow-up insert must build an in-bounds replacement range (no crash / no NSRange fault).
	e.insertText("!")
	#expect(e.attributedString.string == "Hi!")
}

@Test func externalTextReplacementKeepsInBoundsState() {
	let e = engine("Hello world")
	e.setSelectedRange(NSRange(location: 0, length: 5)) // "Hello", still valid in longer text
	e.update(attributedString: NSAttributedString(string: "Hello there, friend"))
	#expect(e.selectionRange == NSRange(location: 0, length: 5)) // preserved — still in bounds
}

@Test func droppedSelectionClearsAnchorSoLaterMoveCantResurrectIt() {
	let e = engine("Hello world")
	e.setSelectedRange(NSRange(location: 1, length: 6)) // anchor 1, cursor 7
	e.update(attributedString: NSAttributedString(string: "Hi!!")) // length 4 → selection out of bounds
	#expect(e.selectionRange == nil) // dropped
	// A later move must be a plain caret move, not a selection extended from the stale anchor.
	e.updateSelection(to: 3)
	#expect(e.selectionRange == nil)
	#expect(e.cursorIndex == 3)
}

// MARK: - Undo / Redo (Phase 1: engine core — coalesced typing + discrete delete)

@Test func typingRunUndoesAndRedoesAsOneStep() {
	let e = engine("")
	e.insertText("a"); e.insertText("b"); e.insertText("c")
	#expect(e.attributedString.string == "abc")
	e.undoManager.undo()
	#expect(e.attributedString.string == "")   // the whole coalesced run reverts in one undo
	e.undoManager.redo()
	#expect(e.attributedString.string == "abc")
}

@Test func caretMoveBreaksTypingIntoSeparateUndoSteps() {
	let e = engine("")
	e.insertText("ab")             // run 1
	e.moveCursor(direction: .left) // caret move ends the run
	e.insertText("X")              // run 2 → "aXb"
	#expect(e.attributedString.string == "aXb")
	e.undoManager.undo()
	#expect(e.attributedString.string == "ab")  // only run 2 undone
	e.undoManager.undo()
	#expect(e.attributedString.string == "")    // run 1 undone separately
}

@Test func deleteIsADiscreteUndoStep() {
	let e = engine("abc") // cursor at end
	e.deleteBackward()
	#expect(e.attributedString.string == "ab")
	e.undoManager.undo()
	#expect(e.attributedString.string == "abc")
}

@Test func undoRestoresSelectionAndCaret() {
	let e = engine("hello world")
	e.setSelectedRange(NSRange(location: 0, length: 5)) // select "hello"
	e.insertText("Hi")                                  // replace → "Hi world"
	#expect(e.attributedString.string == "Hi world")
	e.undoManager.undo()
	#expect(e.attributedString.string == "hello world")
	#expect(e.selectionRange == NSRange(location: 0, length: 5)) // selection restored, not just text
}

@Test func usesInjectedUndoManager() {
	let m = UndoManager(); m.groupsByEvent = false
	let e = PorticoTextLayoutEngine(attributedString: NSAttributedString(string: ""),
									bounds: CGSize(width: 200, height: 200), undoManager: m)
	#expect(e.undoManager === m)
	e.insertText("x")
	#expect(m.canUndo)
	m.undo()
	#expect(e.attributedString.string == "")
}

@Test func externalReplacementClearsUndoStack() {
	let e = engine("")
	e.insertText("abc")
	#expect(e.undoManager.canUndo)
	e.update(attributedString: NSAttributedString(string: "loaded document")) // document reset
	#expect(!e.undoManager.canUndo) // only Portico's actions were cleared (target-scoped)
}

@Test func engineDeallocatesDespiteUndoRegistrations() {
	// Retain-cycle contract: the manager holds the engine unowned and the handler captures only
	// the snapshot, so registering undo must not keep the engine alive.
	weak var weakEngine: PorticoTextLayoutEngine?
	autoreleasepool {
		let e = engine("")
		e.insertText("abc") // registers an undo targeting the engine
		weakEngine = e
	}
	#expect(weakEngine == nil)
}

// MARK: - selectionRange normalization + zero-length targeting (backs iOS replace)

@Test func selectionRangeCollapsesZeroLengthToNil() {
	let e = engine("abcdefg")
	e.selectionRange = NSRange(location: 3, length: 0) // publicly settable; must normalize
	#expect(e.selectionRange == nil)
}

@Test func zeroLengthSetSelectedRangeTargetsItsLocationOnInsert() {
	// Mirrors UITextInput.replace with a zero-length range (QuickType / point insertion): the
	// insert must land at the range's location, not the old cursor. Regression for the
	// selectionRange-normalization interaction.
	let e = engine("abcdefg")
	e.cursorIndex = 0
	e.setSelectedRange(NSRange(location: 5, length: 0))
	e.insertText("X")
	#expect(e.attributedString.string == "abcdeXfg") // inserted at 5, not at 0
}

// MARK: - index(from:moving:) — orientation-aware caret movement (backs iOS UITextInput nav)

@Test func indexUpDownMoveByLineInHorizontalText() {
	let e = engine("abc\ndef") // line0 [0,4) "abc\n", line1 [4,7) "def"
	#expect(e.index(from: 1, moving: .down) >= 4) // b (line0) → line1, not just +1 char
	#expect(e.index(from: 5, moving: .up) <= 3)   // e (line1) → line0
	#expect(e.index(from: 5, moving: .left) == 4) // left/right stay character moves
	#expect(e.index(from: 5, moving: .right) == 6)
}

@Test func indexLeftRightMoveByColumnInVerticalText() {
	let e = engine("abc\ndef", orientation: .vertical) // col0 [0,4), col1 [4,7); RTL columns
	#expect(e.index(from: 1, moving: .left) >= 4)  // col0 → col1 (next line, visually left in RTL)
	#expect(e.index(from: 5, moving: .right) <= 3) // col1 → col0 (previous line)
	#expect(e.index(from: 5, moving: .up) == 4)    // up/down stay character moves within the column
	#expect(e.index(from: 5, moving: .down) == 6)
}

@Test func indexClampsAtDocumentBounds() {
	let e = engine("abc")
	#expect(e.index(from: 0, moving: .left) == 0)  // at start, no move
	#expect(e.index(from: 3, moving: .right) == 3) // at end, no move
}

// MARK: - anchorRectForSelection (popover anchor, §7.2 first-segment policy)

@Test func anchorRectForSelectionNilWithoutSelection() {
	#expect(engine("Hello").anchorRectForSelection() == nil)
}

@Test func anchorRectForSelectionWorksForPlainSelection() {
	let e = engine("Hello world")
	e.setSelectedRange(NSRange(location: 0, length: 5)) // plain text, no ruby
	#expect(e.anchorRectForSelection() != nil) // plain selections now anchor — the point of §7.2
}

@Test func anchorRectForSelectionIsFirstSegmentNotUnionHorizontal() {
	let e = engine("abc\ndef") // two lines
	let range = NSRange(location: 0, length: 7)
	e.setSelectedRange(range)
	let rects = e.selectionRects(for: range)
	#expect(rects.count >= 2) // genuinely spans two line segments
	let unionHeight = rects.dropFirst().reduce(rects[0]) { $0.union($1) }.height
	let anchor = e.anchorRectForSelection()
	#expect(anchor != nil)
	#expect(anchor!.height < unionHeight) // one line tall — first segment, not the two-line union
}

@Test func anchorRectForSelectionUsesFirstColumnVertical() {
	let e = engine("abc\ndef", orientation: .vertical) // two columns
	let range = NSRange(location: 0, length: 7)
	e.setSelectedRange(range)
	let rects = e.selectionRects(for: range)
	#expect(rects.count >= 2)
	let unionWidth = rects.dropFirst().reduce(rects[0]) { $0.union($1) }.width
	let anchor = e.anchorRectForSelection()
	#expect(anchor != nil)
	#expect(anchor!.width < unionWidth) // one column wide — first segment, not the multi-column union
}
