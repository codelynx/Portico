import Foundation
import CoreText
import CoreGraphics
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum PorticoLayoutOrientation {
	case horizontal
	case vertical
}

/// Whole-text outline (縁取り / fuchi). `width` is the ARTIST-FACING rim thickness
/// in points — the visible halo outside the glyph edge. Core Text strokes are
/// centered on the glyph path, so the stroke pass uses lineWidth = 2 × width and
/// `inkBounds()` outsets by exactly `width`. A non-finite or ≤ 0 width behaves as
/// no outline. Drawn BEHIND the fill; affects `draw(in:)`, `drawText(in:)`, and
/// `inkBounds()` identically.
public struct PorticoTextOutline: Equatable {
	public var width: CGFloat
	public var color: CGColor

	public init(width: CGFloat, color: CGColor) {
		self.width = width
		self.color = color
	}

	public static func == (lhs: PorticoTextOutline, rhs: PorticoTextOutline) -> Bool {
		lhs.width == rhs.width && CFEqual(lhs.color, rhs.color)
	}
}

@MainActor
public class PorticoTextLayoutEngine {
	public var attributedString: NSAttributedString
	public var orientation: PorticoLayoutOrientation
	public private(set) var bounds: CGSize
	public var cursorIndex: Int = 0
	public var selectionRange: NSRange? {
		didSet {
			// Normalize a zero-length selection to nil so "non-nil ⇒ a real span" is an actual
			// invariant, not a convention — `selectionRange` is publicly settable, so a client can
			// assign an empty range directly. (Reassigning here does not re-invoke didSet.)
			if let r = selectionRange, r.length == 0 { selectionRange = nil }
			if oldValue != selectionRange { selectionDidChange?(selectionRange) }
		}
	}
	public var markedRange: NSRange?
	/// Fired whenever the selection changes (nil when it collapses to a caret). Lets a client
	/// observe the selected range — e.g. to drive a ruby-reading editor. Mirrors `textDidChange`.
	public var selectionDidChange: ((NSRange?) -> Void)?
	/// Whether the engine draws its own selection highlight. macOS keeps this on (it owns
	/// rendering); iOS turns it off so `UITextInteraction` renders the native selection
	/// tint + handles, avoiding a doubled fill.
	public var drawsSelectionHighlight: Bool = true

	/// Whether the engine draws the caret itself: when it owns rendering (macOS) OR the
	/// text is vertical — UIKit's `UITextInteraction` can't render a vertical-text caret
	/// (it collapses our wide-short caret rect to a stub), so the engine draws it even when
	/// iOS otherwise owns selection. Computed from the live `orientation` so a runtime
	/// orientation change can't leave it stale. Affects `draw(in:)` only — for a
	/// display/raster render with no editing chrome, use `drawText(in:)`.
	public var drawsCaret: Bool { drawsSelectionHighlight || orientation == .vertical }
	private var selectionAnchorIndex: Int?
	public var textDidChange: ((NSAttributedString) -> Void)?
	/// Base attributes for text entering an EMPTY document (font, colour,
	/// paragraph style). Without a preceding or following character there is
	/// nothing to inherit from — and the old empty-dictionary fallback made
	/// the first typed run silently lose its font: laid out and measured at
	/// Core Text defaults (12pt), diverging from the same content parsed
	/// with attributes. Hosts that seed an engine with an empty string MUST
	/// set this to the same attributes they parse content with.
	public var typingAttributes: [NSAttributedString.Key: Any] = [:]

	/// Attributes for text entering the document at `target`: inherit from
	/// the character BEFORE the replaced span; at the head of a non-empty
	/// document, from the first character AFTER it; in an empty document,
	/// from `typingAttributes`.
	private func inheritedAttributes(
		at target: NSRange, in string: NSAttributedString
	) -> [NSAttributedString.Key: Any] {
		var attributes: [NSAttributedString.Key: Any]
		if target.location > 0, target.location - 1 < string.length {
			attributes = string.attributes(at: target.location - 1, effectiveRange: nil)
		} else if target.location + target.length < string.length {
			attributes = string.attributes(at: target.location + target.length, effectiveRange: nil)
		} else {
			attributes = typingAttributes
		}
		return attributes
	}

	/// True when an insertion at `location` (replacing `length` chars) lands strictly inside a
	/// single 縦中横 override span — the chars on both sides carry the SAME `Override` box (identity,
	/// not equality: same box keeps it one run) — so inserted text extends the span. At a span
	/// boundary this is false and the insertion is plain (ruby's attribute-edge rule, same
	/// rationale — see `insertionExtendsRubyGroup`; review fold pinned interior-extend as parity).
	private func insertionExtendsOverrideSpan(at location: Int, replacing length: Int, in string: NSAttributedString) -> Bool {
		let beforeIndex = location - 1
		let afterIndex = location + length
		guard beforeIndex >= 0, afterIndex < string.length else { return false }
		guard let before = string.attribute(PorticoTateChuYoko.overrideKey, at: beforeIndex, effectiveRange: nil) as? PorticoTateChuYoko.Override,
			  let after = string.attribute(PorticoTateChuYoko.overrideKey, at: afterIndex, effectiveRange: nil) as? PorticoTateChuYoko.Override
		else { return false }
		return before === after
	}
	/// Framework-internal (set by `PorticoView`, **not** part of the client observation API): fired
	/// after every content relayout so the view repaints on engine-driven changes it didn't
	/// initiate — undo/redo, a client's `setRuby`. A **single slot** the view overwrites, so a live
	/// engine backs **one view** at a time (a second view over the same engine would fight over
	/// input/IME anyway).
	var onNeedsDisplay: (() -> Void)?
	/// Set while relaying out purely for a bounds change (from the view's draw path), so the
	/// `onNeedsDisplay` repaint isn't re-scheduled from inside drawing.
	private var relayingOutForBounds = false

	/// The undo stack for this engine's edits (see Docs/UndoRedo-Design.md). Undo is **model-scoped**:
	/// it lives with the engine, not the view, so it's independent per engine and survives view
	/// teardown while the client retains the engine. A per-platform view vends this via its
	/// `undoManager` override, so ⌘Z / Edit ▸ Undo / shake drive it. Defaults to a private manager
	/// (bounded via `levelsOfUndo`); a host document app can inject its own to compose undo.
	public let undoManager: UndoManager
	/// True while a run of plain typing is being coalesced into a single undo step. Reset by any
	/// break (caret/selection move, delete, marked text, external replacement, or a restore).
	private var typingRunOpen = false
	/// Captured at IME composition start (first `setMarkedText`); on commit it becomes the one undo
	/// step that reverts the whole composition to its pre-composition state (§6). No steps register
	/// while composing.
	private var preCompositionSnapshot: EditSnapshot?

	private var frameSetter: CTFramesetter?
	private var textFrame: CTFrame?

	public init(attributedString: NSAttributedString, orientation: PorticoLayoutOrientation = .horizontal, bounds: CGSize = .zero, undoManager: UndoManager? = nil,
				typingAttributes: [NSAttributedString.Key: Any] = [:]) {
		self.attributedString = attributedString
		self.orientation = orientation
		self.bounds = bounds
		if !typingAttributes.isEmpty {
			// Construction-site contract: hosts seeding an EMPTY engine pass the
			// base attributes here (discoverable where the empty engine is born).
			self.typingAttributes = typingAttributes
		} else if attributedString.length > 0 {
			// Non-empty seed: capture the first run's attributes as the fallback,
			// so select-all → delete → type doesn't drop to CT defaults in hosts
			// that never set `typingAttributes`. Insertion into non-empty text
			// inherits from neighbors and never consults this; it only matters
			// once the document has been emptied. Ruby/IME-underline are
			// per-run state, not typing defaults — strip them.
			var captured = attributedString.attributes(at: 0, effectiveRange: nil)
			captured.removeValue(forKey: PorticoRuby.rubyKey)
			captured.removeValue(forKey: NSAttributedString.Key(kCTUnderlineStyleAttributeName as String))
			self.typingAttributes = captured
		}
		if let undoManager {
			self.undoManager = undoManager
		} else {
			let m = UndoManager()
			m.levelsOfUndo = 100 // bound memory: snapshots × unlimited would grow without end
			m.groupsByEvent = false // we group each edit step explicitly, not by run-loop cycle
			self.undoManager = m
		}
		self.cursorIndex = attributedString.length
		updateLayout()
	}

	// Remove this engine's registered actions when it deallocates. Harmless for the default
	// manager (it dies with the engine), but essential when a host manager is **injected**: the
	// manager holds the engine unowned, so leftover actions would target a freed engine and crash
	// the host's next undo. `isolated` runs the cleanup on the main actor (the engine is @MainActor).
	isolated deinit {
		undoManager.removeAllActions(withTarget: self)
	}

	// MARK: - Undo / Redo (snapshot per step; see Docs/UndoRedo-Design.md)

	/// A restorable edit state. Restoring it reproduces the text and caret/selection exactly —
	/// including `selectionAnchorIndex`, so a Shift+Arrow after an undo still extends from the
	/// right end. The attributed string is stored as an **immutable copy** so a later mutation of
	/// the (mutable) instance the engine was holding can't corrupt history.
	private struct EditSnapshot {
		let attributedString: NSAttributedString
		let cursorIndex: Int
		let selectionRange: NSRange?
		let selectionAnchorIndex: Int?
	}

	private func currentSnapshot() -> EditSnapshot {
		EditSnapshot(attributedString: attributedString.copy() as! NSAttributedString,
					 cursorIndex: cursorIndex, selectionRange: selectionRange,
					 selectionAnchorIndex: selectionAnchorIndex)
	}

	/// Restore a snapshot without going through the edit paths (so it doesn't re-register undo or
	/// clear the stack). Not `update(attributedString:)` — that's the document-reset path.
	private func restore(_ snapshot: EditSnapshot) {
		typingRunOpen = false
		preCompositionSnapshot = nil
		attributedString = snapshot.attributedString
		cursorIndex = snapshot.cursorIndex
		markedRange = nil
		selectionAnchorIndex = snapshot.selectionAnchorIndex // restore the anchor, not just the range
		updateLayout()
		selectionRange = snapshot.selectionRange // didSet fires selectionDidChange
		textDidChange?(attributedString)
	}

	/// Register an undo that restores `before`. Target-based with the engine held **unowned** by the
	/// manager (Foundation doesn't retain undo targets) and the handler capturing only the snapshot
	/// — so there's no `engine → manager → handler → engine` retain cycle. On undo it captures the
	/// current state as the redo and re-registers, giving working redo.
	private func registerUndo(restoring before: EditSnapshot) {
		undoManager.registerUndo(withTarget: self) { engine in
			let redo = engine.currentSnapshot()
			engine.restore(before)
			engine.registerUndo(restoring: redo)
		}
	}

	/// Register one undo group restoring `before`. Grouped explicitly (the manager is
	/// `groupsByEvent = false`) so each step is a self-contained undo, independent of run-loop timing.
	private func registerUndoStep(restoring before: EditSnapshot) {
		undoManager.beginUndoGrouping()
		registerUndo(restoring: before)
		undoManager.endUndoGrouping()
	}

	/// Capture the pre-edit state for a **discrete** (non-coalesced) step. Call before mutating.
	private func beginUndoStep() {
		typingRunOpen = false
		registerUndoStep(restoring: currentSnapshot())
	}

	/// Capture the pre-edit state only at the **start** of a typing run; subsequent keystrokes in
	/// the run register nothing, so one undo reverts the whole run. Call before mutating.
	private func beginCoalescedTypingStep() {
		guard !typingRunOpen else { return }
		registerUndoStep(restoring: currentSnapshot())
		typingRunOpen = true
	}

	public func update(attributedString: NSAttributedString) {
		// A change in content is a document reset. Identical content is a no-op: keep undo history
		// (a direct-engine client calling this idempotently mustn't lose its stack) and skip relayout.
		guard !self.attributedString.isEqual(attributedString) else { return }
		// Document reset: clear only *our* registered actions (never the whole manager — a
		// host-injected one owns the app's history too), and end any typing run.
		undoManager.removeAllActions(withTarget: self)
		typingRunOpen = false
		preCompositionSnapshot = nil
		self.attributedString = attributedString
		clampEditStateToBounds()
		updateLayout()
	}

	/// Normalize cursor/selection/marked state into the current string bounds. A client can drive
	/// `update(attributedString:)` with a shorter document, leaving `cursorIndex`,
	/// `selectionRange`, `markedRange`, or the anchor pointing past the new end — the next
	/// `insertText`/`setMarkedText` would then build an out-of-bounds replacement range. As the
	/// state-normalization gate for these public-mutable properties, it also rejects negative
	/// locations/lengths, not just past-the-end ones. The cursor is clamped into `0...length`;
	/// selection/marked ranges that no longer fit are dropped (a partially clamped selection is
	/// semantically meaningless). Dropping a selection also clears `selectionAnchorIndex`, so a
	/// later `updateSelection`/Shift+Arrow can't resurrect the gone selection from a stale anchor.
	/// `selectionRange`'s `didSet` notifies observers when dropping changes what's observable.
	private func clampEditStateToBounds() {
		let length = attributedString.length
		cursorIndex = min(max(cursorIndex, 0), length)
		if let sr = selectionRange, sr.location < 0 || sr.length < 0 || NSMaxRange(sr) > length {
			selectionRange = nil
			selectionAnchorIndex = nil
		}
		if let anchor = selectionAnchorIndex, anchor < 0 || anchor > length {
			selectionAnchorIndex = nil
		}
		if let mr = markedRange, mr.location < 0 || mr.length < 0 || NSMaxRange(mr) > length {
			markedRange = nil
		}
	}
	
	public func update(bounds: CGSize) {
		if self.bounds != bounds {
			self.bounds = bounds
			relayingOutForBounds = true // a bounds relayout comes from draw(); don't re-schedule a repaint
			defer { relayingOutForBounds = false }
			updateLayout()
		}
	}
	
	public func update(orientation: PorticoLayoutOrientation) {
		if self.orientation != orientation {
			self.orientation = orientation
			updateLayout()
		}
	}
	
	public func beginSelection(at index: Int) {
		typingRunOpen = false // a caret/selection change ends a coalesced typing run
		cursorIndex = index
		selectionAnchorIndex = index
		selectionRange = nil
	}

	public func updateSelection(to index: Int) {
		typingRunOpen = false
		cursorIndex = index
		if let anchor = selectionAnchorIndex {
			if anchor == index {
				selectionRange = nil
			} else {
				let start = min(anchor, index)
				let length = abs(anchor - index)
				selectionRange = NSRange(location: start, length: length)
			}
		}
	}

	/// Sets the selection from an external source (e.g. UIKit's `selectedTextRange`),
	/// seeding the internal anchor so a later Shift+Arrow (`moveCursor`) extends from
	/// the right end instead of a nil/stale anchor. A zero-length range collapses to a
	/// caret; otherwise the anchor is the range start and the cursor its end.
	public func setSelectedRange(_ range: NSRange) {
		typingRunOpen = false
		if range.length == 0 {
			cursorIndex = range.location
			selectionRange = nil
			selectionAnchorIndex = nil
		} else {
			cursorIndex = range.location + range.length
			selectionRange = range
			selectionAnchorIndex = range.location
		}
	}
	
	/// The word range containing `index` (system word segmentation, including Japanese kanji /
	/// kana boundaries), or nil if `index` isn't within a word (e.g. whitespace/punctuation).
	/// Backs double-click word selection.
	public func wordRange(at index: Int) -> NSRange? {
		// 縦中横: a group IS the word for any probe inside it — the system
		// tokenizer handles digit pairs but returns nothing useful for the
		// bang pairs ("!?"), which are pinned v1 groups (review fold).
		for group in currentTateChuYokoGroups() {
			if index >= group.location, index < group.location + group.length {
				return group
			}
		}
		let ns = attributedString.string as NSString
		guard ns.length > 0 else { return nil }
		let probe = max(0, min(index, ns.length - 1))
		var result: NSRange?
		ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
							   options: [.byWords, .substringNotRequired]) { _, wordRange, _, stop in
			if NSLocationInRange(probe, wordRange) {
				result = wordRange
				stop.pointee = true
			} else if wordRange.location > probe {
				stop.pointee = true // enumeration is in order; past the probe, so no word contains it
			}
		}
		return result
	}

	public func setMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange?) {
		typingRunOpen = false // IME composition boundary breaks a typing run; no undo step while marked
		if markedRange == nil { preCompositionSnapshot = currentSnapshot() } // composition start
		let mutableString = NSMutableAttributedString(attributedString: attributedString)

		let targetRange: NSRange
		if let repRange = replacementRange, repRange.location != NSNotFound {
			targetRange = repRange
		} else if let mr = markedRange {
			targetRange = mr
		} else if let sr = selectionRange {
			targetRange = sr
		} else {
			targetRange = NSRange(location: cursorIndex, length: 0)
		}

		let attrs = inheritedAttributes(at: targetRange, in: mutableString)
		var markedAttrs = attrs
		markedAttrs[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
		// Same ruby attribute-edge rule as insertText: composing text joins a ruby group only
		// when strictly inside one; at a boundary it must not inherit the base's ruby (§6).
		if !insertionExtendsRubyGroup(at: targetRange.location, replacing: targetRange.length, in: mutableString) {
			markedAttrs.removeValue(forKey: PorticoRuby.rubyKey)
		}
		// Same edge rule for 縦中横 overrides: extend strictly inside, plain at a boundary.
		if !insertionExtendsOverrideSpan(at: targetRange.location, replacing: targetRange.length, in: mutableString) {
			markedAttrs.removeValue(forKey: PorticoTateChuYoko.overrideKey)
		}

		let insertedString = NSAttributedString(string: text, attributes: markedAttrs)
		mutableString.replaceCharacters(in: targetRange, with: insertedString)
		
		self.markedRange = text.isEmpty ? nil : NSRange(location: targetRange.location, length: text.utf16.count)
		self.selectionRange = nil
		self.cursorIndex = targetRange.location + selectedRange.location
		
		self.attributedString = mutableString
		textDidChange?(self.attributedString)
		updateLayout()
	}
	
	public func unmarkText() {
		guard let mr = markedRange else { return }
		// Finalizing a composition via unmark (rather than a committing insertText) is also a commit:
		// Finalize the composition *first* (drop the underline, clear the marked range), then
		// register the undo step against the committed state — so the step and its redo reflect the
		// finalized text, not the still-underlined marked intermediate, and the no-op check compares
		// the committed string (not one that differs only by the temporary underline).
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		mutableString.removeAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String), range: mr)
		self.attributedString = mutableString
		self.markedRange = nil

		if let pre = preCompositionSnapshot {
			if !attributedString.isEqual(pre.attributedString) { registerUndoStep(restoring: pre) }
			preCompositionSnapshot = nil
		}
		textDidChange?(self.attributedString)
		updateLayout()

		// Commit-path parity (witness fold, V7): unmark IS a commit, so the
		// inline conversion must fire here exactly as in insertText — Kotoeri
		// can finalize a composition through unmark (click-confirm and some
		// Enter flows), and without this the just-committed `》` never
		// converts. Same undo shape: the conversion is its own step.
		if importsAozoraRubyWhileTyping { applyInlineRubyConversion() }
	}
	
	public enum MoveDirection {
		case left, right, up, down
	}
	
	private func targetIndex(for direction: MoveDirection) -> Int {
		return index(from: cursorIndex, moving: direction)
	}

	/// The string index reached by moving one step in `direction` from `from`, interpreted per
	/// orientation — horizontal: L/R = character, U/D = line (via the caret rect ± its height);
	/// vertical (RTL columns): L = next column, R = previous column, U/D = character. **Pure**: it
	/// reads no `cursorIndex` and mutates nothing, so it backs both `moveCursor` (caret) and the
	/// iOS `UITextInput` navigation queries (`position(from:in:)`, `characterRange(byExtending:)`)
	/// from an arbitrary starting position.
	func index(from: Int, moving direction: MoveDirection) -> Int {
		switch direction {
		case .left:
			if orientation == .horizontal {
				return max(0, from - 1)
			} else {
				// Probe by the COLUMN PITCH, not the caret rect's width — the
				// 縦中横 interior caret is a 2pt vertical bar (local inline
				// direction), and a width-based probe from it would land in
				// the SAME column (slice-4 review catch). Pitch is the
				// column-to-column distance by definition, shape-independent.
				let rect = caretRect(for: from)
				let point = CGPoint(x: rect.midX - effectiveLinePitch, y: rect.midY)
				return stringIndex(for: point)
			}
		case .right:
			if orientation == .horizontal {
				return min(attributedString.length, from + 1)
			} else {
				let rect = caretRect(for: from)
				let point = CGPoint(x: rect.midX + effectiveLinePitch, y: rect.midY)
				return stringIndex(for: point)
			}
		case .up:
			if orientation == .horizontal {
				let rect = caretRect(for: from)
				let point = CGPoint(x: rect.midX, y: rect.midY + rect.height)
				return stringIndex(for: point)
			} else {
				return max(0, from - 1)
			}
		case .down:
			if orientation == .horizontal {
				let rect = caretRect(for: from)
				let point = CGPoint(x: rect.midX, y: rect.midY - rect.height)
				return stringIndex(for: point)
			} else {
				return min(attributedString.length, from + 1)
			}
		}
	}
	
	public func moveCursor(direction: MoveDirection, modifySelection: Bool = false) {
		typingRunOpen = false // moving the caret ends a coalesced typing run
		let target = targetIndex(for: direction)

		if modifySelection {
			if selectionRange == nil {
				beginSelection(at: cursorIndex)
			}
			updateSelection(to: target)
		} else {
			cursorIndex = target
			selectionRange = nil
			selectionAnchorIndex = nil
		}
	}

	/// True when an insertion at `location` (replacing `length` chars) lands strictly inside a
	/// single ruby group — the chars on both sides belong to the same contiguous ruby run — so
	/// inserted text should inherit the ruby and extend the group. At a group boundary this is
	/// false and the insertion is plain text. See Docs/RubyEditing-Design.md §6.
	private func insertionExtendsRubyGroup(at location: Int, replacing length: Int, in string: NSAttributedString) -> Bool {
		let beforeIndex = location - 1
		let afterIndex = location + length
		guard beforeIndex >= 0, afterIndex < string.length else { return false }
		var beforeRange = NSRange(location: 0, length: 0)
		guard string.attribute(PorticoRuby.rubyKey, at: beforeIndex, effectiveRange: &beforeRange) != nil else { return false }
		return NSLocationInRange(afterIndex, beforeRange)
	}

	public func insertText(_ text: String) {
		// Undo granularity (§6): committing an IME composition (markedRange set) is one discrete step
		// back to the pre-composition state captured at composition start — not a snapshot of the
		// underlined marked candidate. Plain typing coalesces into a run. Composition updates
		// themselves register nothing (see setMarkedText).
		if markedRange != nil, let pre = preCompositionSnapshot {
			typingRunOpen = false
			registerUndoStep(restoring: pre)
			preCompositionSnapshot = nil
		} else if markedRange == nil {
			preCompositionSnapshot = nil // a plain committed keystroke means no active composition
			beginCoalescedTypingStep()
		}
		let mutableString = NSMutableAttributedString(attributedString: attributedString)

		let targetRange: NSRange
		if let mr = markedRange {
			targetRange = mr
		} else if let sr = selectionRange {
			targetRange = sr
		} else {
			targetRange = NSRange(location: cursorIndex, length: 0)
		}

		let attrs = inheritedAttributes(at: targetRange, in: mutableString)
		var cleanAttrs = attrs
		// Don't carry the IME underline into committed text.
		cleanAttrs.removeValue(forKey: NSAttributedString.Key(kCTUnderlineStyleAttributeName as String))
		// Ruby attribute-edge rule: inserted text joins a ruby group only when it lands
		// strictly inside one; at a group boundary it is plain text — fixes typing after a
		// base extending its ruby. See Docs/RubyEditing-Design.md §6.
		if !insertionExtendsRubyGroup(at: targetRange.location, replacing: targetRange.length, in: mutableString) {
			cleanAttrs.removeValue(forKey: PorticoRuby.rubyKey)
		}
		// Same edge rule for 縦中横 overrides: extend strictly inside, plain at a boundary.
		if !insertionExtendsOverrideSpan(at: targetRange.location, replacing: targetRange.length, in: mutableString) {
			cleanAttrs.removeValue(forKey: PorticoTateChuYoko.overrideKey)
		}

		let insertedString = NSAttributedString(string: text, attributes: cleanAttrs)
		mutableString.replaceCharacters(in: targetRange, with: insertedString)
		self.cursorIndex = targetRange.location + text.utf16.count
		self.selectionRange = nil
		self.markedRange = nil

		self.attributedString = mutableString
		textDidChange?(self.attributedString)
		updateLayout()

		// Inline notation (§7a): a just-typed `》` closing `…《reading》` converts to a ruby group —
		// as a SEPARATE undo step (see applyInlineRubyConversion), so undo returns to the literal
		// characters first. Guarded internally to only fire when a run actually closes.
		// Gated OFF by default since 0.6.0 (owner ruling): Aozora import happens at explicit
		// boundaries (paste, `parse(aozora:)`), not during default typing.
		if importsAozoraRubyWhileTyping { applyInlineRubyConversion() }
	}

	/// Opt-in live Aozora conversion while typing: a just-typed `》` closing `[｜]base《reading》`
	/// converts to a ruby group (own undo step — always escapable). Default `false` (0.6.0 owner
	/// ruling): the owned notation is `PorticoNotation`; Aozora is a one-way import that fires at
	/// explicit boundaries (paste, `parse(aozora:)`). Hosts whose only ruby input is inline typing
	/// (e.g. MangaLoft until it grows a ruby menu) opt in deliberately.
	/// Known misfire when enabled: `《》` is legitimate punctuation for titles (《吾輩は猫である》),
	/// so a title typed right after kanji converts to surprise ruby; undo reverses it in one step.
	public var importsAozoraRubyWhileTyping = false

	// MARK: - Clipboard round-trip (backs macOS copy/cut/paste)
	// Ruby and 縦中横 overrides survive copy/paste through the OWNED notation (PorticoNotation):
	// Copy serializes the selection, Paste parses it back — identity for Portico-originated
	// content; external plain text additionally gets the one-way Aozora import.

	/// Set / edit / remove the ruby reading over `range` as **one undo step** (nil, empty, or
	/// whitespace-only removes it). The base text is unchanged, so the caret/selection are
	/// preserved. This is the undoable ruby-edit command a client drives (design §4) instead of
	/// replacing the whole document via the binding. No-op (and no undo step) if the range is empty
	/// or out of bounds, or if the reading doesn't actually change. Assumes no active IME composition
	/// (the views commit composition before delivering structural commands).
	public func setRuby(_ reading: String?, for range: NSRange) {
		guard range.length > 0, range.location >= 0, NSMaxRange(range) <= attributedString.length else { return }
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		PorticoRuby.setRuby(reading, for: range, in: mutableString)
		// No-op check must compare ruby **semantics**, not `isEqual`: setRuby attaches a fresh
		// CTRubyAnnotation, so re-applying the same reading is not `isEqual` and would push a dead
		// undo step. Compare the (base, reading) groups instead. (Base text is unchanged. Foreign
		// values under the ruby key aren't genuine groups, so a setRuby that would only clear one
		// counts as a no-op here — not ours to manage.)
		let full = NSRange(location: 0, length: attributedString.length)
		func rubyKey(_ s: NSAttributedString) -> [String] {
			PorticoRuby.rubyGroups(in: full, of: s).map { "\($0.base.location),\($0.base.length)=\($0.reading)" }
		}
		guard rubyKey(attributedString) != rubyKey(mutableString) else { return }
		beginUndoStep()
		attributedString = mutableString
		textDidChange?(attributedString)
		updateLayout()
	}

	/// Apply or clear a 縦中横 override (0.6.0 PR-1). Range surgery (review
	/// fold): every override span INTERSECTING `range` is cleared first, so a
	/// partial overlap replaces the intersection cleanly (ruby's surgery
	/// template); then `kind` (if non-nil) applies over the whole range as
	/// ONE identity-boxed span. No-op calls (clearing where nothing exists)
	/// push no undo step. Precedence with ruby is handled at DERIVATION
	/// (ruby wins); nesting is not expressible in serialization.
	public func setTateChuYoko(_ kind: PorticoTateChuYoko.Override.Kind?, for range: NSRange) {
		guard range.length > 0, range.location >= 0,
		      NSMaxRange(range) <= attributedString.length else { return }
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		var touched = false
		mutableString.enumerateAttribute(
			PorticoTateChuYoko.overrideKey,
			in: NSRange(location: 0, length: mutableString.length)
		) { value, spanRange, _ in
			guard value != nil, NSIntersectionRange(spanRange, range).length > 0 else { return }
			mutableString.removeAttribute(PorticoTateChuYoko.overrideKey, range: spanRange)
			touched = true
		}
		if let kind {
			mutableString.addAttribute(
				PorticoTateChuYoko.overrideKey,
				value: PorticoTateChuYoko.Override(kind),
				range: range)
			touched = true
		}
		guard touched else { return }
		beginUndoStep()
		attributedString = mutableString
		textDidChange?(attributedString)
		updateLayout()
	}

	/// The state-dependent menu verb for `range`, evaluated AT MENU-OPEN TIME
	/// (0.6.0 PR-3): `.release` ("縦中横を解除") when the whole range already
	/// renders inside 縦中横 cells; `.apply` ("縦中横") otherwise — a MIXED
	/// selection resolves APPLY-WINS (design OQ-A, the bold-editor convention).
	public enum TateChuYokoToggle { case apply, release }
	public func tateChuYokoToggle(for range: NSRange) -> TateChuYokoToggle {
		guard range.length > 0, NSMaxRange(range) <= attributedString.length else { return .apply }
		var covered = 0
		for group in PorticoTateChuYoko.effectiveGroups(in: attributedString) {
			covered += NSIntersectionRange(group, range).length
		}
		return covered == range.length ? .release : .apply
	}

	/// Perform the toggle `tateChuYokoToggle(for:)` names. Apply normalizes the
	/// whole selection into ONE combine span (surgery clears any suppress —
	/// "縦中横 on a suppressed range removes the suppress", never a
	/// suppress-still-wins surprise). Release makes the selection stop
	/// rendering 縦中横: explicit overrides intersecting it are cleared, and
	/// automatic groups still intersecting it after that are SUPPRESSED
	/// (their full atomic ranges) — one undo step either way.
	///
	/// SNAP rule (witness fold, V3): apply operates at the same granularity
	/// the selection HIGHLIGHT communicates — whole cells. A selection edge
	/// falling inside an effective group highlights the whole cell (the v1
	/// visual rule), so the range snaps OUTWARD to cover every intersected
	/// group in full; otherwise a `月1` grabber stop that *paints* as `月10`
	/// would combine `月1` and orphan the `0` (three per-spec rules composing
	/// into a WYSIWYG break). The foreclosed sub-cell selection is one the UI
	/// cannot even display, so no intent is lost.
	public func performTateChuYokoToggle(for range: NSRange) {
		guard range.length > 0, NSMaxRange(range) <= attributedString.length else { return }
		switch tateChuYokoToggle(for: range) {
		case .apply:
			var snapped = range
			for group in PorticoTateChuYoko.effectiveGroups(in: attributedString)
			where NSIntersectionRange(group, range).length > 0 {
				snapped = NSUnionRange(snapped, group)
			}
			setTateChuYoko(.combine, for: snapped)
		case .release:
			releaseTateChuYoko(in: range)
		}
	}

	private func releaseTateChuYoko(in range: NSRange) {
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		var touched = false
		mutableString.enumerateAttribute(
			PorticoTateChuYoko.overrideKey,
			in: NSRange(location: 0, length: mutableString.length)
		) { value, spanRange, _ in
			guard value != nil, NSIntersectionRange(spanRange, range).length > 0 else { return }
			mutableString.removeAttribute(PorticoTateChuYoko.overrideKey, range: spanRange)
			touched = true
		}
		// What still renders 縦中横 here is automatic — suppress it. (A cleared
		// 3+-length combine has no auto group underneath, so clearing sufficed.)
		for group in PorticoTateChuYoko.effectiveGroups(in: mutableString)
		where NSIntersectionRange(group, range).length > 0 {
			mutableString.addAttribute(
				PorticoTateChuYoko.overrideKey,
				value: PorticoTateChuYoko.Override(.suppress),
				range: group)
			touched = true
		}
		guard touched else { return }
		beginUndoStep()
		attributedString = mutableString
		textDidChange?(attributedString)
		updateLayout()
	}

	/// The 縦中横 override covering `index`, if any — the menu-title seam
	/// (state-dependent toggle) and tests read this.
	public func tateChuYokoOverride(at index: Int) -> PorticoTateChuYoko.Override.Kind? {
		guard index >= 0, index < attributedString.length else { return nil }
		let value = attributedString.attribute(
			PorticoTateChuYoko.overrideKey, at: index, effectiveRange: nil)
		return (value as? PorticoTateChuYoko.Override)?.kind
	}

	/// The current selection serialized to the OWNED notation (`PorticoNotation` — ruby and
	/// 縦中横 overrides preserved), or nil if there is no non-empty selection. Plain text
	/// serializes to itself (no marks). Switched from the Aozora path in 0.6.0 PR-3: parse
	/// mints a fresh identity box per tcy command, so copy/paste-adjacent yields DISTINCT
	/// cells by construction (the review's paste-coalescing hazard).
	func serializedSelection() -> String? {
		guard let sr = selectionRange, sr.length > 0 else { return nil }
		return PorticoNotation.serialize(attributedString.attributedSubstring(from: sr))
	}

	/// Parse notation and insert it at the current target range (replacing any selection),
	/// giving the pasted text the insertion context's base attributes (font/colour) while
	/// keeping its parsed annotations. Two layers, both one-way into the model:
	/// 1. the OWNED grammar (`[[ruby:…]]`/`[[tcy:…]]` — internal copy/paste round-trip);
	/// 2. with `importingAozora`, an Aozora pass over the remaining PLAIN segments
	///    (`漢字《かんじ》` pasted from an external manuscript) — the paste boundary is an
	///    explicit import boundary (owner ruling 2026-07-04), unlike default typing.
	/// The view layer passes `importingAozora: false` for Portico-originated pasteboard
	/// content (release-review blocker: internal copy/paste must be IDENTITY — literal
	/// `《》` a user typed must not turn into ruby on the way back in); the Aozora pass runs
	/// only for external plain text.
	func insertNotation(_ notation: String, importingAozora: Bool = true) {
		beginUndoStep() // paste is one discrete undo step
		let pasteTarget = markedRange ?? selectionRange ?? NSRange(location: cursorIndex, length: 0)
		var contextAttrs = inheritedAttributes(at: pasteTarget, in: attributedString)
		contextAttrs.removeValue(forKey: NSAttributedString.Key(kCTUnderlineStyleAttributeName as String))
		contextAttrs.removeValue(forKey: PorticoRuby.rubyKey)
		// Pasted notation carries its own annotations; never inherit an override from the context.
		contextAttrs.removeValue(forKey: PorticoTateChuYoko.overrideKey)
		let parsed = NSMutableAttributedString(
			attributedString: PorticoNotation.parse(notation, attributes: contextAttrs))
		if importingAozora { PorticoRuby.importAozora(in: parsed) }
		insertAttributedText(parsed)
	}

	/// Replace the current target range (marked ▸ selection ▸ caret) with `attributed`, preserving
	/// its attributes (incl. ruby), and advance the caret past it.
	private func insertAttributedText(_ attributed: NSAttributedString) {
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		let targetRange: NSRange
		if let mr = markedRange { targetRange = mr }
		else if let sr = selectionRange { targetRange = sr }
		else { targetRange = NSRange(location: cursorIndex, length: 0) }
		mutableString.replaceCharacters(in: targetRange, with: attributed)
		self.cursorIndex = targetRange.location + attributed.length
		self.selectionRange = nil
		self.markedRange = nil
		self.attributedString = mutableString
		textDidChange?(self.attributedString)
		updateLayout()
	}

	/// If the caret just closed an inline ruby run `[｜]base《reading》`, convert it to a ruby group
	/// (§7a) as its **own** undo step — the typing run is closed first, so undo #1 reverts the
	/// conversion to the literal `《》` characters and undo #2 reverts the typing (design §4).
	/// No-op when nothing closes a run.
	///
	/// Aozora posture (0.6.0 review): this live conversion is a deliberate ONE-WAY IMPORT at
	/// typing time — the same quarantine class as `PorticoNotation.parse(aozora:)`. Nothing ever
	/// serializes back to `《》`; the clean-break claim is about representation, not input
	/// convenience. Undo #1 restores the literal characters, so the conversion is always escapable.
	///
	/// Note: on the converting keystroke, `textDidChange` fires **twice** — once for the literal
	/// notation (from `insertText`) and once for the converted group (here). Both are synchronous
	/// within the one call, so no intermediate frame is drawn — view rendering normally sees only
	/// the final state — but a direct observer (e.g. autosave / dirty-tracking) sees both
	/// transitions. This mirrors the two undo steps and is intentional.
	private func applyInlineRubyConversion() {
		guard cursorIndex > 0 else { return }
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		guard let match = PorticoRuby.inlineRubyMatch(
				in: mutableString.string as NSString,
				closingAt: cursorIndex - 1,
				// Auto-base must not swallow a character already in a ruby group.
				isRuby: { mutableString.attribute(PorticoRuby.rubyKey, at: $0, effectiveRange: nil) != nil })
		else { return }
		typingRunOpen = false
		beginUndoStep() // discrete step: its snapshot is the literal notation just typed
		// Keep the base with its attributes, drop the marks + reading, then attach the ruby.
		let base = NSMutableAttributedString(attributedString: mutableString.attributedSubstring(from: match.baseRange))
		PorticoRuby.setRuby(match.reading, for: NSRange(location: 0, length: base.length), in: base)
		mutableString.replaceCharacters(in: match.sourceRange, with: base)
		cursorIndex = match.sourceRange.location + base.length
		selectionRange = nil
		markedRange = nil
		attributedString = mutableString
		textDidChange?(attributedString)
		updateLayout()
	}
	
	public func deleteBackward() {
		// A delete is a discrete undo step (never coalesced into a typing run). Register only if
		// something will actually be deleted, so a no-op backspace doesn't push an empty undo.
		guard selectionRange != nil || cursorIndex > 0 else { return }
		beginUndoStep()
		let mutableString = NSMutableAttributedString(attributedString: attributedString)

		if let range = selectionRange {
			mutableString.deleteCharacters(in: range)
			self.cursorIndex = range.location
			self.selectionRange = nil
		} else {
			guard cursorIndex > 0 else { return }
			// Delete a whole composed character sequence (grapheme cluster), not one UTF-16
			// unit — otherwise a surrogate-pair character (emoji, CJK-ext) or a combining
			// sequence would be split into an invalid string.
			let range = (mutableString.string as NSString).rangeOfComposedCharacterSequence(at: cursorIndex - 1)
			mutableString.deleteCharacters(in: range)
			self.cursorIndex = range.location
		}
		
		self.attributedString = mutableString
		textDidChange?(self.attributedString)
		updateLayout()
	}
	
	public func stringIndex(for point: CGPoint) -> Int {
		guard let hit = lineHit(for: point) else { return 0 }
		let index = CTLineGetStringIndexForPosition(hit.line, hit.relativePoint)
		// 縦中横 interior-tap rule (0.6.0 REV 2 — supersedes the v1 cell-half
		// snap): a tap inside a group's cell resolves via the MINI-LINE's own
		// gap geometry — the glyphs run horizontally inside the cell, so the
		// tap's X picks the nearest glyph gap (including interior gaps, which
		// 3+-length combines need reachable). Real-editor behavior: a center
		// tap on "12" parks between the digits.
		for group in currentTateChuYokoGroups() {
			guard index > group.location, index < group.location + group.length,
			      let cell = tateChuYokoCell(for: group) else { continue }
			let baseAttributes = attributedString.attributes(at: group.location, effectiveRange: nil)
			let mini = PorticoTateChuYoko.miniLine(
				groupText: (attributedString.string as NSString).substring(with: group),
				baseAttributes: baseAttributes,
				cellCross: cell.width,
				stroke: nil)
			let drawX = cell.midX - mini.width / 2
			let local = CTLineGetStringIndexForPosition(
				mini.line, CGPoint(x: point.x - drawX, y: 0))
			guard local != kCFNotFound else { return group.location }
			return group.location + max(0, min(local, group.length))
		}
		return index
	}

	/// Glyph *containing* `point` (containment semantics), for hit-testing. A tap on a glyph's
	/// trailing half resolves to **that** glyph — not the following caret gap, as
	/// `stringIndex(for:)` does (caret placement wants the nearest gap; hit-testing doesn't).
	/// Points before/after the text yield an out-of-range index, which callers treat as "none".
	private func glyphIndex(for point: CGPoint) -> Int {
		guard let hit = lineHit(for: point) else { return 0 }
		let caretIndex = CTLineGetStringIndexForPosition(hit.line, hit.relativePoint)
		let caretOffset = CTLineGetOffsetForStringIndex(hit.line, caretIndex, nil)
		// If the point is before the caret at caretIndex, the glyph under it is the prior one.
		return hit.relativePoint.x < caretOffset ? caretIndex - 1 : caretIndex
	}

	/// The line closest to `point`, and `point` mapped into that line's local advance-axis
	/// space (advance offset in `.x`). Shared by `stringIndex(for:)` and `glyphIndex(for:)`.
	private func lineHit(for point: CGPoint) -> (line: CTLine, relativePoint: CGPoint)? {
		guard let textFrame = textFrame else { return nil }
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return nil }

		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)

		var closestLineIndex = 0
		var minDistance: CGFloat = .greatestFiniteMagnitude
		for i in 0..<lines.count {
			let origin = origins[i]
			let dist = orientation == .vertical ? abs(point.x - origin.x) : abs(point.y - origin.y)
			if dist < minDistance {
				minDistance = dist
				closestLineIndex = i
			}
		}

		let origin = origins[closestLineIndex]
		let relativePoint: CGPoint
		if orientation == .vertical {
			// Vertical text: the CTLine's advance axis (X) maps to the visual Y axis (downward).
			relativePoint = CGPoint(x: origin.y - point.y, y: 0)
		} else {
			relativePoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
		}
		return (lines[closestLineIndex], relativePoint)
	}
	
	public func rect(forCharacterRange range: NSRange) -> CGRect {
		guard let textFrame = textFrame else { return .zero }
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return .zero }
		
		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)
		
		for i in 0..<lines.count {
			let line = lines[i]
			let lineRange = CTLineGetStringRange(line)
			let nsLineRange = NSRange(location: lineRange.location, length: lineRange.length)
			let intersection = NSIntersectionRange(nsLineRange, range)
			
			if intersection.length > 0 {
				let startOffset = CTLineGetOffsetForStringIndex(line, intersection.location, nil)
				let endOffset = CTLineGetOffsetForStringIndex(line, intersection.location + intersection.length, nil)
				
				var ascent: CGFloat = 0
				var descent: CGFloat = 0
				var leading: CGFloat = 0
				CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
				
				let origin = origins[i]
				let rectWidthOrHeight = endOffset > startOffset ? endOffset - startOffset : startOffset - endOffset
				
				if orientation == .vertical {
					let yBottom = origin.y - max(startOffset, endOffset)
					return CGRect(x: origin.x - descent, y: yBottom, width: ascent + descent, height: rectWidthOrHeight)
				} else {
					let xLeft = origin.x + min(startOffset, endOffset)
					return CGRect(x: xLeft, y: origin.y - descent, width: rectWidthOrHeight, height: ascent + descent)
				}
			}
		}
		
		return caretRect(for: range.location)
	}
	
	public func caretRect(for index: Int) -> CGRect {
		guard let textFrame = textFrame else {
			// Laid-out-empty documents still need a caret (host chrome can
			// be fully hidden in the empty state — the caret is then the
			// editor's ONLY visible artifact).
			return attributedString.length == 0 ? emptyDocumentCaretRect() : .zero
		}
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return emptyDocumentCaretRect() }
		
		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)

		// 縦中横 interior (slice-4 witness finding): inside a group the
		// LOCAL inline direction is horizontal — the caret between the
		// upright characters is a VERTICAL bar between them, not the
		// column-shaped bar (which strikes through the pair). Position
		// comes from the mini-line's own CT offset (matches the drawn
		// glyphs exactly, including compression and asymmetric pairs);
		// y-span is the mini-line's glyph height, so the caret reads as
		// belonging to the text. Boundary carets (index at group start/end)
		// deliberately fall through to the column shape.
		for group in currentTateChuYokoGroups() {
			guard index > group.location, index < group.location + group.length,
			      let cell = tateChuYokoCell(for: group) else { continue }
			let baseAttributes = attributedString.attributes(at: group.location, effectiveRange: nil)
			let mini = PorticoTateChuYoko.miniLine(
				groupText: (attributedString.string as NSString).substring(with: group),
				baseAttributes: baseAttributes,
				cellCross: cell.width,
				stroke: nil)
			let localOffset = CGFloat(CTLineGetOffsetForStringIndex(
				mini.line, index - group.location, nil))
			let drawX = cell.midX - mini.width / 2
			let baseline = cell.midY - (mini.ascent - mini.descent) / 2
			let pathBounds = CTLineGetBoundsWithOptions(mini.line, [.useGlyphPathBounds])
			let ySpan: (y: CGFloat, height: CGFloat)
			if !pathBounds.isNull, !pathBounds.isEmpty {
				ySpan = (baseline + pathBounds.minY, pathBounds.height)
			} else {
				ySpan = (baseline - mini.descent, mini.ascent + mini.descent)
			}
			return CGRect(x: drawX + localOffset - 1, y: ySpan.y, width: 2, height: ySpan.height)
		}

		// Extra line fragment: the caret after a TRAILING hard break sits at
		// the head of a line that has no CTLine yet — synthesize it from the
		// last real line's origin advanced one pitch on the block axis
		// (leftward column for vertical, downward line for horizontal), at
		// inline offset 0 (the line head). Without this the offset-past-the-
		// newline formula below drops the caret past the END of the previous
		// line — visually outside the box.
		if index == attributedString.length, hasTrailingLineBreak,
		   let lastOrigin = origins.last, let lastLine = lines.last {
			var ascent: CGFloat = 0
			var descent: CGFloat = 0
			var leading: CGFloat = 0
			CTLineGetTypographicBounds(lastLine, &ascent, &descent, &leading)
			let pitch = effectiveLinePitch
			if orientation == .vertical {
				let caretThickness: CGFloat = 2
				return CGRect(
					x: lastOrigin.x - pitch - descent,
					y: lastOrigin.y - caretThickness, // inline offset 0 = column top
					width: ascent + descent,
					height: caretThickness)
			} else {
				return CGRect(
					x: lastOrigin.x, // inline offset 0 = line head
					y: lastOrigin.y - pitch - descent,
					width: 2,
					height: ascent + descent)
			}
		}
		
		for i in 0..<lines.count {
			let line = lines[i]
			let range = CTLineGetStringRange(line)
			
			// Check if index is within this line. 
			// If it's the absolute end of the string, it belongs to the last line.
			let isLastLine = i == lines.count - 1
			if (index >= range.location && index < range.location + range.length) || (isLastLine && index == range.location + range.length) {
				let origin = origins[i]
				
				var ascent: CGFloat = 0
				var descent: CGFloat = 0
				var leading: CGFloat = 0
				CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
				
				let offset = CTLineGetOffsetForStringIndex(line, index, nil)
				
				if orientation == .vertical {
					let caretThickness: CGFloat = 2
					let x = origin.x - descent
					// CoreText vertical offsets move down visually, so we subtract from Y.
					// Bias the caret past the boundary in the writing direction (downward,
					// toward the next glyph) — mirroring the horizontal caret's rightward
					// bias — so a caret at the top of a column isn't clipped above origin.y.
					let y = origin.y - offset - caretThickness
					return CGRect(x: x, y: y, width: ascent + descent, height: caretThickness)
				} else {
					let x = origin.x + offset
					let y = origin.y - descent
					return CGRect(x: x, y: y, width: 2, height: ascent + descent)
				}
			}
		}
		return .zero
	}

	/// The empty document's caret — synthesized via a one-glyph PROBE
	/// layout: an ideographic space carrying `typingAttributes` (what the
	/// first typed character will inherit) laid out in the SAME frame with
	/// the SAME pipeline attributes, whose index-0 caret is taken exactly
	/// as the main formula would. Bit-parity with where the first real
	/// glyph's caret lands, for both orientations, without duplicating
	/// CT's line-placement conventions in arithmetic.
	private func emptyDocumentCaretRect() -> CGRect {
		guard bounds.width > 0, bounds.height > 0 else { return .zero }
		let probe = NSMutableAttributedString(string: "\u{3000}", attributes: typingAttributes)
		let fullRange = NSRange(location: 0, length: probe.length)
		// MERGE the pitch into any paragraph style the typing attributes
		// carry — same treatment as `layoutReadyString` — so alignment /
		// indents survive and the empty caret sits exactly where the first
		// typed character's caret will (review F3: a fresh style here made
		// a center-aligned empty editor's caret jump on the first key).
		let paragraph = layoutParagraphStyle(
			from: typingAttributes[.paragraphStyle] as? NSParagraphStyle, lineHeight: layoutLineHeight)
		probe.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
		if orientation == .vertical {
			probe.addAttribute(.verticalGlyphForm, value: true, range: fullRange)
		}
		let setter = CTFramesetterCreateWithAttributedString(probe as CFAttributedString)
		// ⛔ The probe must FIT, or Core Text lays out no line and the caret vanishes. An empty
		// document measures as zero, so a host sizing its editor to the measurement gets a box
		// smaller than one line pitch (MangaLoft: a 14 pt vertical editor at its 24 pt minimum,
		// pitch ≈ 25+ with the ruby allowance) — the empty caret was silently zero there. Lay the
		// probe out in a box at least one cell big, then pin that box to the real one at the
		// WRITING-START edges (top + right for vertical, top + left for horizontal): exactly where
		// the first typed character will appear.
		let unbounded: CGFloat = 1_000_000
		let cell = CTFramesetterSuggestFrameSizeWithConstraints(
			setter, CFRangeMake(0, 0), layoutFrameAttributes as CFDictionary,
			CGSize(width: unbounded, height: unbounded), nil)
		let layoutSize = CGSize(
			width: max(bounds.width, ceil(cell.width)), height: max(bounds.height, ceil(cell.height)))
		let path = CGMutablePath()
		path.addRect(CGRect(origin: .zero, size: layoutSize))
		let frame = CTFramesetterCreateFrame(
			setter, CFRangeMake(0, 0), path, layoutFrameAttributes as CFDictionary)
		let lines = CTFrameGetLines(frame) as! [CTLine]
		guard let line = lines.first else { return .zero }
		var origins = [CGPoint](repeating: .zero, count: 1)
		CTFrameGetLineOrigins(frame, CFRangeMake(0, 1), &origins)
		// Core Text is y-up: keeping the TOP aligned shifts y by the height difference; vertical
		// text grows leftward from the right edge, so keeping the RIGHT aligned shifts x too.
		let shiftX = orientation == .vertical ? bounds.width - layoutSize.width : 0
		let shiftY = bounds.height - layoutSize.height
		let origin = CGPoint(x: origins[0].x + shiftX, y: origins[0].y + shiftY)
		var ascent: CGFloat = 0
		var descent: CGFloat = 0
		var leading: CGFloat = 0
		CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
		if orientation == .vertical {
			let caretThickness: CGFloat = 2
			return CGRect(
				x: origin.x - descent, y: origin.y - caretThickness,
				width: ascent + descent, height: caretThickness)
		} else {
			return CGRect(x: origin.x, y: origin.y - descent, width: 2, height: ascent + descent)
		}
	}

	/// Fill rects for `range` in layout (Core Text, bottom-left origin)
	/// coordinates, IN DOCUMENT ORDER — usually one per line, but a 縦中横 cell
	/// partially covered by the range contributes its own clipped rect, so one
	/// line/column can yield several. Unlike `rect(forCharacterRange:)`, which
	/// returns only the first line, this spans a multi-line selection. Shared by
	/// the on-screen selection highlight and iOS `UITextInput.selectionRects(for:)`
	/// (both of which rely on the ordering).
	public func selectionRects(for range: NSRange) -> [CGRect] {
		// 縦中横 partial-cell highlight (0.6.x slice — supersedes the slice-4
		// P5 whole-cell expansion): a group PARTIALLY covered by `range` clips
		// its cell rect in the cell's LOCAL inline direction via the
		// mini-line's own glyph offsets — the highlight edge moves through the
		// cell exactly as the stored per-character selection does (Shift+
		// arrows, grabber drags), instead of painting the whole cell for any
		// intersection. A FULLY covered group still paints as the whole cell —
		// the plain per-line math below yields that naturally, because the
		// reservation offsets at group boundaries ARE the cell edges. The
		// stored selection/marked RANGE is untouched either way.
		// DOCUMENT ORDER is a postcondition (review blocker): consumers infer
		// position from array order — `firstSegmentRect` takes .first as "the
		// selection's first segment", and the iOS bridge assigns containsStart/
		// containsEnd from array ends (grabber attachment). So the pieces are
		// merge-walked in source order, never "all plain then all partial".
		guard range.length > 0 else { return [] }
		var partials: [(group: NSRange, covered: NSRange)] = []
		var remainder = [range]
		for group in currentTateChuYokoGroups() {
			let covered = NSIntersectionRange(group, range)
			guard covered.length > 0, covered != group else { continue }
			partials.append((group, covered))
			remainder = remainder.flatMap { PorticoTateChuYoko.subtract([group], from: $0) }
		}
		enum Piece { case plain(NSRange); case partial(group: NSRange, covered: NSRange) }
		var pieces: [(location: Int, piece: Piece)] =
			remainder.filter { $0.length > 0 }.map { ($0.location, .plain($0)) }
			+ partials.map { ($0.covered.location, .partial(group: $0.group, covered: $0.covered)) }
		pieces.sort { $0.location < $1.location }

		var rects: [CGRect] = []
		for (_, piece) in pieces {
			switch piece {
			case .plain(let fragment):
				// plainSelectionRects emits per-line rects in line (document) order.
				rects.append(contentsOf: plainSelectionRects(for: fragment))
			case .partial(let group, let covered):
				if let rect = partialTateChuYokoCellRect(group: group, covered: covered) {
					rects.append(rect)
				} else {
					// Unlaid cell (shouldn't happen for a rendered selection):
					// fall back to the pre-slice whole-cell paint.
					rects.append(contentsOf: plainSelectionRects(for: group))
				}
			}
		}
		return rects
	}

	/// The pre-partial per-line rect math: one rect per line the range touches,
	/// from the layout line's own offsets (which, across a whole 縦中横 group,
	/// are the reservation's cell edges).
	private func plainSelectionRects(for range: NSRange) -> [CGRect] {
		guard let textFrame = textFrame, range.length > 0 else { return [] }
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return [] }

		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)

		var rects: [CGRect] = []
		for i in 0..<lines.count {
			let line = lines[i]
			let lineRange = CTLineGetStringRange(line)
			let nsLineRange = NSRange(location: lineRange.location, length: lineRange.length)
			let intersection = NSIntersectionRange(nsLineRange, range)
			guard intersection.length > 0 else { continue }

			let startOffset = CTLineGetOffsetForStringIndex(line, intersection.location, nil)
			let endOffset = CTLineGetOffsetForStringIndex(line, intersection.location + intersection.length, nil)

			var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
			CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

			let origin = origins[i]
			let extent = abs(endOffset - startOffset)
			if orientation == .vertical {
				let yBottom = origin.y - max(startOffset, endOffset)
				rects.append(CGRect(x: origin.x - descent, y: yBottom, width: ascent + descent, height: extent))
			} else {
				let xLeft = origin.x + min(startOffset, endOffset)
				rects.append(CGRect(x: xLeft, y: origin.y - descent, width: extent, height: ascent + descent))
			}
		}
		return rects
	}

	/// The highlight rect for the `covered` sub-range of a PARTIALLY selected
	/// 縦中横 group: the cell rect clipped in the cell's local inline direction
	/// (the glyphs run horizontally inside the cell), with edges from the
	/// MINI-LINE's own glyph offsets — the same geometry the interior caret and
	/// gap taps use, so the highlight edge lands exactly between the drawn
	/// glyphs (including compression and asymmetric pairs). Full cell height:
	/// the upright glyphs occupy the whole cell vertically.
	private func partialTateChuYokoCellRect(group: NSRange, covered: NSRange) -> CGRect? {
		guard let cell = tateChuYokoCell(for: group) else { return nil }
		let baseAttributes = attributedString.attributes(at: group.location, effectiveRange: nil)
		let mini = PorticoTateChuYoko.miniLine(
			groupText: (attributedString.string as NSString).substring(with: group),
			baseAttributes: baseAttributes,
			cellCross: cell.width,
			stroke: nil)
		let drawX = cell.midX - mini.width / 2
		let localStart = covered.location - group.location
		let localEnd = NSMaxRange(covered) - group.location
		let startOffset = CGFloat(CTLineGetOffsetForStringIndex(mini.line, localStart, nil))
		let endOffset = localEnd >= group.length
			? mini.width
			: CGFloat(CTLineGetOffsetForStringIndex(mini.line, localEnd, nil))
		return CGRect(x: drawX + min(startOffset, endOffset), y: cell.minY,
		              width: abs(endOffset - startOffset), height: cell.height)
	}

	// MARK: - Ruby geometry (Phase 3, step 4)
	// Layout (Core Text, bottom-left) coordinates — platform view wrappers flip to view
	// coordinates, as with `caretRect` / `selectionRects`. These let a client build tap /
	// popover ruby editing (design §5). Rects cover the group's **base** glyphs; the reading
	// renders within the line's ascent above/beside the base.

	/// Per-line base rects of the ruby group containing `index`, or `[]` if `index` isn't in a
	/// group. One rect per line the base spans.
	public func rects(forRubyGroupContaining index: Int) -> [CGRect] {
		guard let group = PorticoRuby.rubyGroup(at: index, in: attributedString) else { return [] }
		return selectionRects(for: group.base)
	}

	/// A single rect enclosing the ruby group containing `index` — the union of its per-line
	/// base rects — suitable for anchoring a popover. `.null` if `index` isn't in a group.
	public func anchorRect(forRubyGroupContaining index: Int) -> CGRect {
		let groupRects = rects(forRubyGroupContaining: index)
		guard let first = groupRects.first else { return .null }
		return groupRects.dropFirst().reduce(first) { $0.union($1) }
	}

	/// The **first segment in document/layout order** of `range` — its run on the first line
	/// (horizontal) / first column (vertical RTL order), in layout coordinates — or `.null` if the
	/// range is empty or unlaid. This is the popover-anchor policy (design §7.2): compact and
	/// stable, unlike the union (arbitrary in vertical/wrapped) or the active end (drag-direction
	/// dependent, undefined for word-select / right-click). `selectionRects` yields rects in
	/// document order (a stated postcondition), so its first element is exactly the first
	/// segment — including a partial 縦中横 cell rect when the selection starts inside a cell.
	private func firstSegmentRect(for range: NSRange) -> CGRect {
		return selectionRects(for: range).first ?? .null
	}

	/// SwiftUI-client convenience: a **popover-anchor** rect (not a selection-bounds rect) for the
	/// current selection, in **top-left / SwiftUI coordinates** (layout rect flipped by the current
	/// bounds), or nil when there's no non-empty selection. Anchors to the selection's first segment
	/// in document order (§7.2). Works for **any** selection — ruby or plain — so a client can float
	/// one editor surface next to any selection.
	public func anchorRectForSelection() -> CGRect? {
		guard let range = selectionRange, range.length > 0 else { return nil }
		let r = firstSegmentRect(for: range)
		guard !r.isNull else { return nil }
		return CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
	}

	/// The ruby group at `point` (layout coordinates), or nil. Uses **containment** hit-testing
	/// (a tap anywhere on a base glyph — including its trailing half — resolves to that glyph),
	/// so tap-to-edit works even on a one-kanji base. Taps on the reading glyphs are approximate
	/// (they resolve via the nearest base character, since Core Text doesn't fully contain the
	/// ruby ascent).
	public func rubyGroup(at point: CGPoint) -> (base: NSRange, reading: String)? {
		PorticoRuby.rubyGroup(at: glyphIndex(for: point), in: attributedString)
	}

	/// Metrics of a representative CJK line in the string's own base attributes (the font Core
	/// Text actually uses, including CJK fallbacks): its natural typographic height — ascent +
	/// descent + the font's leading — and that leading on its own.
	///
	/// ⭐ The natural height IS the default pitch: glyph box plus the font's own gap (1.5 em for
	/// Hiragino — a half-em gap between columns, exactly the room half-size ruby needs, so ruby
	/// fits without a reserve). ⛔ Until 2026-09-25 the pitch was measured from a line CARRYING
	/// ruby (2.0 em) and Core Text then added the leading AGAIN (see `layoutLineHeight`), so 14 pt
	/// vertical text laid out 2.5 em apart — gaps wider than the letters (artist report).
	private func baseLineMetrics() -> (pitch: CGFloat, leading: CGFloat) {
		var attrs = attributedString.length > 0
			? attributedString.attributes(at: 0, effectiveRange: nil)
			: typingAttributes
		attrs.removeValue(forKey: NSAttributedString.Key(kCTRubyAnnotationAttributeName as String))
		let sample = NSAttributedString(string: "永", attributes: attrs) // representative CJK glyph
		let line = CTLineCreateWithAttributedString(sample as CFAttributedString)
		var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
		CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
		return (ascent + descent + leading, leading)
	}

	/// Line origins of the current frame, in layout coordinates. Exposed for tests
	/// that assert uniform line pitch.
	func lineOrigins() -> [CGPoint] {
		guard let textFrame = textFrame else { return [] }
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return [] }
		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)
		return origins
	}

	/// Scales the uniform line pitch — the distance between successive line / column origins.
	/// 1.0 (default) = the font's natural pitch (glyph box + its own leading; 1.5 em for
	/// Hiragino, which holds half-size ruby in the gap); < 1 tightens (ruby may touch the next
	/// line — the client's judgment); > 1 loosens. Clamped to [0.5, 3]; non-finite values are
	/// ignored. Setting a different value relayouts (and repaints a live view). Affects layout,
	/// `measuredSize`, and rendering identically — it feeds the one shared pitch, which is now
	/// the REAL column advance (the leading Core Text inserts is subtracted before layout).
	public var linePitchMultiplier: CGFloat {
		get { _linePitchMultiplier }
		set {
			guard newValue.isFinite else { return } // NaN/∞ ignored (min/max pass NaN through)
			let clamped = min(max(newValue, 0.5), 3.0)
			guard clamped != _linePitchMultiplier else { return }
			_linePitchMultiplier = clamped
			updateLayout()
		}
	}
	private var _linePitchMultiplier: CGFloat = 1.0

	/// The distance between successive line / column origins — what every consumer means by
	/// "pitch" (cursor moves between columns, the next-line caret, the `measuredSize` floor).
	private var effectiveLinePitch: CGFloat { baseLineMetrics().pitch * _linePitchMultiplier }

	/// The FIXED line height handed to Core Text — equal to the pitch, because
	/// `layoutParagraphStyle` also pins Core Text's line SPACING. Unpinned, Core Text inserts a
	/// font leading between fixed-height lines (measured: min = max = 28 → origins 35 apart at
	/// 14 pt Hiragino). ⚠️ Subtracting the sample glyph's leading instead is wrong: the leading
	/// Core Text adds is not necessarily the sample's (Latin-only text in a zero-leading font got
	/// none, and `linePitchScalesLineAdvance` failed), so the spacing is pinned instead.
	private var layoutLineHeight: CGFloat { max(1, effectiveLinePitch) }

	/// The Core Text paragraph style a layout copy carries: the caller's `NSParagraphStyle`
	/// fields, plus the fixed line height, plus line spacing pinned to the caller's `lineSpacing`
	/// (default 0). ⭐ The pin is the point: `NSParagraphStyle` cannot say "maximum line spacing",
	/// and without it Core Text adds each line's font leading on top of the fixed height, so the
	/// real pitch was the requested one plus half an em for CJK fonts (2026-09-25).
	private static func ctAlignment(_ alignment: NSTextAlignment) -> CTTextAlignment {
		switch alignment {
		case .left: .left
		case .right: .right
		case .center: .center
		case .justified: .justified
		default: .natural
		}
	}

	private func layoutParagraphStyle(from source: NSParagraphStyle?, lineHeight: CGFloat) -> CTParagraphStyle {
		let style = source ?? NSParagraphStyle.default
		var alignment = Self.ctAlignment(style.alignment)
		var lineBreak = CTLineBreakMode(rawValue: UInt8(style.lineBreakMode.rawValue)) ?? .byWordWrapping
		var direction = CTWritingDirection(rawValue: Int8(style.baseWritingDirection.rawValue)) ?? .natural
		var firstHead = style.firstLineHeadIndent, head = style.headIndent, tail = style.tailIndent
		var after = style.paragraphSpacing, before = style.paragraphSpacingBefore
		var height = lineHeight, spacing = max(0, style.lineSpacing)
		var tabInterval = style.defaultTabInterval
		var tabs: CFArray = style.tabStops.map { tab in
			CTTextTabCreate(Self.ctAlignment(tab.alignment), Double(tab.location), tab.options as CFDictionary)
		} as CFArray
		return withUnsafePointer(to: &alignment) { pAlign in
		withUnsafePointer(to: &lineBreak) { pBreak in
		withUnsafePointer(to: &direction) { pDir in
		withUnsafePointer(to: &firstHead) { pFirst in
		withUnsafePointer(to: &head) { pHead in
		withUnsafePointer(to: &tail) { pTail in
		withUnsafePointer(to: &after) { pAfter in
		withUnsafePointer(to: &before) { pBefore in
		withUnsafePointer(to: &height) { pHeight in
		withUnsafePointer(to: &spacing) { pSpacing in
		withUnsafePointer(to: &tabInterval) { pTabInterval in
		withUnsafePointer(to: &tabs) { pTabs in
			let size = MemoryLayout<CGFloat>.size
			let settings = [
				CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pAlign),
				CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: pBreak),
				CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: pDir),
				CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: size, value: pFirst),
				CTParagraphStyleSetting(spec: .headIndent, valueSize: size, value: pHead),
				CTParagraphStyleSetting(spec: .tailIndent, valueSize: size, value: pTail),
				CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: size, value: pAfter),
				CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: size, value: pBefore),
				CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: size, value: pHeight),
				CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: size, value: pHeight),
				CTParagraphStyleSetting(spec: .minimumLineSpacing, valueSize: size, value: pSpacing),
				CTParagraphStyleSetting(spec: .maximumLineSpacing, valueSize: size, value: pSpacing),
				CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: size, value: pTabInterval),
				CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: pTabs),
			]
			return CTParagraphStyleCreate(settings, settings.count)
		}}}}}}}}}}}}
	}

	/// A trailing hard line break has NO CTLine of its own (the `\n` belongs
	/// to the line it terminates), so the "next line" the user just created
	/// with Return exists only logically until a character lands on it. Both
	/// `measuredSize` (reserve one pitch of block extent) and `caretRect`
	/// (synthesize the next line's head) must account for it — the classic
	/// extra-line-fragment every text engine synthesizes.
	private var hasTrailingLineBreak: Bool {
		attributedString.string.hasSuffix("\n")
	}

	/// Whole-text outline; nil = off (default). Setting a different value (including
	/// a color-only change) invalidates the cached stroke frame and repaints a live
	/// view. Does not relayout — stroke attributes don't change advances (asserted
	/// by the stroke/fill line-origin parity test).
	public var outline: PorticoTextOutline? {
		didSet {
			guard outline != oldValue else { return }
			strokeTextFrame = nil
			onNeedsDisplay?()
		}
	}
	/// The outline as applied: non-finite or ≤ 0 widths behave as off.
	private var activeOutline: PorticoTextOutline? {
		guard let outline, outline.width.isFinite, outline.width > 0 else { return nil }
		return outline
	}
	/// Cached stroke-pass frame; invalidated by relayout and by `outline` changes.
	private var strokeTextFrame: CTFrame?

	/// The invisible ruby that keeps a ruby word on one line (see `layoutReadyString`).
	private static let keepTogetherRuby: CTRubyAnnotation = {
		let attributes: [CFString: Any] = [kCTRubyAnnotationSizeFactorAttributeName: 0.01 as CFNumber]
		return CTRubyAnnotationCreateWithAttributes(
			.center, .auto, .before, "\u{200B}" as CFString, attributes as CFDictionary)
	}()

	/// The inline limit the current layout breaks at: the box's writing-direction extent.
	private var boundsInlineLimit: CGFloat? {
		let extent = orientation == .vertical ? bounds.height : bounds.width
		return extent > 0 ? extent : nil
	}

	/// The typographic ascent of a base range laid out on its own (vertical forms in vertical
	/// text): the distance from the baseline to the glyph box's ruby-side edge.
	private func baseGlyphAscent(of range: NSRange) -> CGFloat {
		let base = NSMutableAttributedString(attributedString: attributedString.attributedSubstring(from: range))
		let full = NSRange(location: 0, length: base.length)
		base.removeAttribute(PorticoRuby.rubyKey, range: full)
		base.removeAttribute(.paragraphStyle, range: full)
		if orientation == .vertical { base.addAttribute(.verticalGlyphForm, value: true, range: full) }
		var ascent: CGFloat = 0
		CTLineGetTypographicBounds(CTLineCreateWithAttributedString(base), &ascent, nil, nil)
		return ascent
	}

	/// A base range's natural advance along the writing direction (its own attributes).
	private func baseAdvance(of range: NSRange) -> CGFloat {
		let base = NSMutableAttributedString(attributedString: attributedString.attributedSubstring(from: range))
		let full = NSRange(location: 0, length: base.length)
		base.removeAttribute(PorticoRuby.rubyKey, range: full)
		if orientation == .vertical { base.addAttribute(.verticalGlyphForm, value: true, range: full) }
		return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(base), nil, nil, nil))
	}

	/// The stroke-pass frame: the layout-ready string with CT stroke attributes
	/// (positive width = stroke-only) framed identically to `textFrame`. Lazily
	/// built and cached. Point width → percent-of-font-size conversion is per run
	/// (mixed sizes stroke correctly even though MangaLoft v1 styles are uniform);
	/// lineWidth = 2 × outline.width because CT centers strokes on the glyph path.
	private func currentStrokeFrame() -> CTFrame? {
		guard let o = activeOutline, textFrame != nil else { return nil }
		if let cached = strokeTextFrame { return cached }

		let strokeString = NSMutableAttributedString(attributedString: layoutReadyString(inlineLimit: boundsInlineLimit))
		let fullRange = NSRange(location: 0, length: strokeString.length)
		let strokeWidthKey = NSAttributedString.Key(kCTStrokeWidthAttributeName as String)
		let strokeColorKey = NSAttributedString.Key(kCTStrokeColorAttributeName as String)

		strokeString.enumerateAttribute(.font, in: fullRange) { value, range, _ in
			let pointSize = Self.pointSize(ofFontAttribute: value)
			// kCTStrokeWidth is a PERCENT of the run's font size; positive = stroke-only.
			let percent = (2 * o.width) / pointSize * 100
			strokeString.addAttribute(strokeWidthKey, value: percent as NSNumber, range: range)
		}
		strokeString.addAttribute(strokeColorKey, value: o.color, range: fullRange)

		// 縦中横 plan-B (slice-4 PR-1 empirical pin: delegates do NOT suppress
		// glyph drawing): group ranges must not paint phantom stroke outlines —
		// zero the stroke width and clear the color for marker runs. The
		// PR-2 post-pass strokes the mini-line itself (fuchi parity).
		if !PorticoTateChuYoko.suppressionDisabledForTesting {
			strokeString.enumerateAttribute(PorticoTateChuYoko.groupKey, in: fullRange) { value, range, _ in
				guard value != nil else { return }
				strokeString.addAttribute(strokeWidthKey, value: 0 as NSNumber, range: range)
				strokeString.addAttribute(strokeColorKey, value: CGColor(gray: 0, alpha: 0), range: range)
			}
		}

		// Ruby is NOT in the layout copy any more (only the invisible keep-together annotation,
		// which must stay identical here so the stroke frame lines up with the fill frame);
		// `drawRuby(in:stroke:)` strokes the readings (ruby-typesetting arc, 2026-09-25).

		let setter = CTFramesetterCreateWithAttributedString(strokeString as CFAttributedString)
		let path = CGMutablePath()
		path.addRect(CGRect(origin: .zero, size: bounds))
		let frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, layoutFrameAttributes as CFDictionary)
		strokeTextFrame = frame
		return frame
	}

	/// Point size of a `.font` attribute value, whatever concrete type it carries
	/// (platform font, CTFont, or absent/unrecognized — Core Text defaults to
	/// Helvetica 12). Non-positive sizes fall back too, so percent conversion can
	/// never divide by zero.
	static func pointSize(ofFontAttribute value: Any?) -> CGFloat {
		let size: CGFloat
		switch value {
		case nil:
			size = 0
		#if canImport(AppKit)
		case let font as NSFont:
			size = font.pointSize
		#elseif canImport(UIKit)
		case let font as UIFont:
			size = font.pointSize
		#endif
		case let some?:
			size = CFGetTypeID(some as CFTypeRef) == CTFontGetTypeID()
				? CTFontGetSize(some as! CTFont)
				: 0
		}
		return size > 0 && size.isFinite ? size : 12
	}

	/// Test hook: the stroke frame's line origins, for the stroke/fill parity
	/// assertion (stroke attributes must not change advances).
	func strokeFrameLineOrigins() -> [CGPoint] {
		guard let frame = currentStrokeFrame() else { return [] }
		let lines = CTFrameGetLines(frame) as! [CTLine]
		guard !lines.isEmpty else { return [] }
		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)
		return origins
	}

	/// The string as actually laid out: the caller's content with the uniform
	/// ruby-reserving line pitch merged into every paragraph style, plus vertical
	/// glyph forms when vertical. Shared by `updateLayout()` and `measuredSize(inlineExtent:)`
	/// so layout and measurement can never disagree (WYSIWYG parity). Independent of
	/// `bounds` — valid on an engine that has never laid out.
	private func layoutReadyString(inlineLimit: CGFloat? = nil) -> NSAttributedString {
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		let fullRange = NSRange(location: 0, length: mutableString.length)

		// RUBY (ruby-typesetting arc, 2026-09-25): Core Text lays out the BASE text only — the
		// reading is drawn by Portico (`drawRuby`), centred on its word, so a long reading never
		// pushes its base and a ruby column never shifts (both came from Core Text's own ruby).
		// A word that fits the inline limit keeps a VESTIGIAL annotation (zero-width reading,
		// 1 % size): Core Text then never splits it across lines (S0 probe — its FULL ruby does
		// not), and it draws nothing and moves no glyph. ⛔ A word LONGER than the limit gets none:
		// kept whole, Core Text falls back to one character per line for the whole text.
		mutableString.removeAttribute(PorticoRuby.rubyKey, range: fullRange)
		for group in PorticoRuby.rubyGroups(in: NSRange(location: 0, length: attributedString.length), of: attributedString) {
			if let inlineLimit, baseAdvance(of: group.base) > inlineLimit { continue }
			mutableString.addAttribute(PorticoRuby.rubyKey, value: Self.keepTogetherRuby, range: group.base)
		}

		// A uniform line-to-line pitch, so lines stay evenly spaced whether or not
		// they carry ruby (no デコボコ): fixed height = pitch, line spacing pinned
		// (`layoutParagraphStyle`). Built FROM any caller-supplied paragraph style,
		// so alignment / indents / spacing / tabs survive.
		let lineHeight = layoutLineHeight
		var styleUpdates: [(NSRange, CTParagraphStyle)] = []
		mutableString.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
			styleUpdates.append((range, layoutParagraphStyle(from: value as? NSParagraphStyle, lineHeight: lineHeight)))
		}
		for (range, style) in styleUpdates {
			mutableString.addAttribute(.paragraphStyle, value: style, range: range)
		}

		if orientation == .vertical {
			// .verticalGlyphForm allows Core Text to substitute vertical variants of characters if the font supports it.
			mutableString.addAttribute(.verticalGlyphForm, value: true, range: fullRange)
			// 縦中横 (slice 4): reserve one column cell per auto-detected group
			// — on the LAYOUT COPY only (the backing store never carries the
			// delegate/marker; typing inheritance and notation serialization
			// stay clean by construction).
			PorticoTateChuYoko.applyReservations(to: mutableString)
		}
		return mutableString
	}

	/// Core Text frame attributes for the current orientation — shared by layout and
	/// measurement (parity covers the progression, not just the prepared string).
	private var layoutFrameAttributes: [CFString: Any] {
		[
			kCTFrameProgressionAttributeName: orientation == .vertical ?
				CTFrameProgression.rightToLeft.rawValue :
				CTFrameProgression.topToBottom.rawValue
		]
	}

	private func updateLayout() {
		defer { if !relayingOutForBounds { onNeedsDisplay?() } } // repaint on content relayout (not bounds)
		strokeTextFrame = nil // stroke pass mirrors the layout; rebuilt lazily on next draw
		guard bounds.width > 0 && bounds.height > 0 else {
			self.frameSetter = nil
			self.textFrame = nil
			return
		}

		let setter = CTFramesetterCreateWithAttributedString(layoutReadyString(inlineLimit: boundsInlineLimit) as CFAttributedString)
		self.frameSetter = setter

		let path = CGMutablePath()
		path.addRect(CGRect(origin: .zero, size: bounds))

		self.textFrame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, layoutFrameAttributes as CFDictionary)
	}

	/// Measures the content's natural LAYOUT size — the rect to lay out or persist
	/// (NOT ink extents; ruby overhang and outline live in ink-bounds territory).
	/// `inlineExtent` is the wrap constraint along the writing direction — width when
	/// horizontal, height when vertical; nil = unconstrained (manual line breaks
	/// only). Results are ceiled to integral points. Uses the exact attribute
	/// pipeline layout uses, so a frame laid out at the returned size shows the full
	/// string. Independent of current `bounds`; valid on an engine that has never
	/// laid out. Alignment positions text within a frame and does not change the
	/// measured size.
	public func measuredSize(inlineExtent: CGFloat? = nil) -> CGSize {
		guard attributedString.length > 0 else { return .zero }
		// Non-finite or non-positive constraints are treated as unconstrained.
		let extent: CGFloat? = inlineExtent.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
		let setter = CTFramesetterCreateWithAttributedString(layoutReadyString(inlineLimit: extent) as CFAttributedString)
		// Generous-but-finite bound for unconstrained axes: CGFloat.greatestFiniteMagnitude
		// is known to make CTFramesetterSuggestFrameSizeWithConstraints misbehave.
		let unbounded: CGFloat = 1_000_000
		let constraint = orientation == .vertical
			? CGSize(width: unbounded, height: extent ?? unbounded)
			: CGSize(width: extent ?? unbounded, height: unbounded)
		let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
			setter, CFRangeMake(0, 0), layoutFrameAttributes as CFDictionary, constraint, nil
		)
		guard suggested.width > 0 && suggested.height > 0 else { return .zero }

		let fullLength = attributedString.length
		func probe(_ candidate: CGSize) -> (fits: Bool, lineCount: Int) {
			let path = CGMutablePath()
			path.addRect(CGRect(origin: .zero, size: candidate))
			let frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, layoutFrameAttributes as CFDictionary)
			return (CTFrameGetVisibleStringRange(frame).length == fullLength, CFArrayGetCount(CTFrameGetLines(frame)))
		}
		func withBlockExtent(_ size: CGSize, _ block: CGFloat) -> CGSize {
			orientation == .vertical
				? CGSize(width: block, height: size.height)
				: CGSize(width: size.width, height: block)
		}

		var size = CGSize(width: ceil(suggested.width), height: ceil(suggested.height))

		// SuggestFrameSize is unreliable under the forced uniform line height, in BOTH
		// directions: it overreports the block axis by a few points (observed), and its
		// historically reported failure mode is UNDER-reporting. Verified-fit beats
		// modeled-fit both ways:
		//
		// 1. End-verify the suggestion; repair UP if it under-reports (sanity-bounded —
		//    the debug assert flags the pathological case).
		var probed = probe(size)
		if !probed.fits {
			var attempts = 0
			var block = orientation == .vertical ? size.width : size.height
			while !probed.fits && attempts < 32 {
				block += 4
				size = withBlockExtent(size, block)
				probed = probe(size)
				attempts += 1
			}
			assert(probed.fits, "measuredSize: no fitting size within +128pt of the suggestion")
		}

		// 2. Tighten DOWN: binary-search the smallest fitting block extent between the
		//    deterministic floor (lineCount × pitch under the uniform pitch) and the
		//    known-fitting current size — fit is monotone in block extent. Skipped as a
		//    PERF guard (not correctness; step 1 already guarantees fit) when caller
		//    block spacing puts the floor uselessly far below the real extent.
		if probed.fits && probed.lineCount > 0 && !hasBlockSpacingBeyondPitch {
			let cap = orientation == .vertical ? size.width : size.height
			let floor = min(cap, ceil(CGFloat(probed.lineCount) * effectiveLinePitch))
			if probe(withBlockExtent(size, floor)).fits {
				size = withBlockExtent(size, floor)
			} else {
				var lo = floor // known not to fit
				var hi = cap   // known to fit
				while hi - lo > 1 {
					let mid = ((lo + hi) / 2).rounded(.down)
					if probe(withBlockExtent(size, mid)).fits { hi = mid } else { lo = mid }
				}
				size = withBlockExtent(size, hi)
			}
		}
		// Extra line fragment: a trailing hard break's "next line" has no
		// CTLine, so the measured block extent must reserve one pitch for it
		// — otherwise Return doesn't grow the box until the next character
		// lands (and the caret has no room to sit in).
		if hasTrailingLineBreak {
			let block = (orientation == .vertical ? size.width : size.height) + ceil(effectiveLinePitch)
			size = withBlockExtent(size, block)
		}
		return size
	}

	/// Whether any caller paragraph style adds block extent on top of the uniform
	/// pitch — paragraph spacing between paragraphs, or line spacing between lines
	/// (Core Text applies `lineSpacing` even with min/max line height clamped).
	/// A PERF guard for `measuredSize`'s tighten step: with such spacing the
	/// lineCount × pitch floor sits uselessly far below the real extent and the
	/// search degenerates. Fit itself is guaranteed by end-verification regardless.
	private var hasBlockSpacingBeyondPitch: Bool {
		var found = false
		attributedString.enumerateAttribute(
			.paragraphStyle,
			in: NSRange(location: 0, length: attributedString.length)
		) { value, _, stop in
			if let style = value as? NSParagraphStyle,
			   style.paragraphSpacing > 0 || style.paragraphSpacingBefore > 0 || style.lineSpacing > 0 {
				found = true
				stop.pointee = true
			}
		}
		return found
	}

	/// Test hook (like `lineOrigins()`): how many characters the current layout shows.
	func visibleStringRangeLength() -> Int {
		guard let textFrame = textFrame else { return 0 }
		return CTFrameGetVisibleStringRange(textFrame).length
	}

	/// Maps a line-local rect (CTLine bounds coordinates: x along the line's advance
	/// axis from the line origin, y baseline-relative with +y on the ascent side) into
	/// engine (Core Text bottom-left) space. Orientation-aware: horizontal lines
	/// advance +x with ascent up; vertical lines advance visually DOWN (engine −y)
	/// with the ascent side extending toward engine +x — the same mapping
	/// `selectionRects(for:)` uses.
	func lineLocalToEngineRect(_ rect: CGRect, lineOrigin origin: CGPoint) -> CGRect {
		if orientation == .vertical {
			return CGRect(
				x: origin.x + rect.minY,
				y: origin.y - rect.maxX,
				width: rect.height,
				height: rect.width
			)
		} else {
			return CGRect(
				x: origin.x + rect.minX,
				y: origin.y + rect.minY,
				width: rect.width,
				height: rect.height
			)
		}
	}

	/// Union of the laid-out glyphs' GEOMETRIC ink extents (Core Text glyph-path
	/// bounds), INCLUDING ruby reading glyphs — which overhang the layout rect on
	/// the ascent side (above the line in horizontal, right of the column in
	/// vertical). Distinct from the layout `bounds`/`measuredSize` (the rect text
	/// is framed into). Clients sizing raster tiles or selection chrome should
	/// start from this rect, not the layout rect — and must still convert to their
	/// target scale and outset for antialiasing (rasterization bleeds ~1px past
	/// geometric bounds). Engine (Core Text bottom-left) coordinates. `.null` when
	/// there is no layout OR no painted glyphs (empty or whitespace/newline-only
	/// content).
	public func inkBounds() -> CGRect {
		guard let textFrame = textFrame else { return .null }
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return .null }
		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)

		var union = CGRect.null
		for (line, origin) in zip(lines, origins) {
			var local = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
			// 縦中横 ink: hidden originals contribute ~NOTHING here — the
			// suppression shrinks them to a sub-pixel font on the layout copy
			// (their paths collapse), so whole-line bounds stay tight without
			// any per-run recomputation. (History: a CTRunGetImageBounds
			// exclusion was tried and reverted — rotated run-space trap; a
			// quantified 4pt over-report pin was tried and FAILED at 36pt —
			// path slack scales with font size. The sub-pixel shrink is the
			// structural fix with no second coordinate space.) Tightness is
			// pinned non-circularly at two sizes, plain + outlined. The
			// mini-line union below supplies the group's real ink.
			// Empty lines (e.g. "\n\n") yield null/empty glyph bounds — skip, or the
			// union degrades. (A group-ONLY line lands here too: its ink is
			// exclusively the mini-line, unioned after this loop.)
			guard !local.isNull, !local.isEmpty else { continue }

			union = union.union(lineLocalToEngineRect(local, lineOrigin: origin))
		}
		// The outline's rim extends exactly `width` past the glyph edge (stroke
		// lineWidth is 2 × width, centered on the path).
		if !union.isNull, let o = activeOutline {
			union = union.insetBy(dx: -o.width, dy: -o.width)
		}
		// Ruby is drawn by Portico, not Core Text: union each reading's glyph-path ink where it is
		// drawn — it may overshoot the layout box on any side (the artist's rule), and the
		// selection box (layout) must not include it while redraw and export (ink) must.
		let rubyOutset = activeOutline?.width ?? 0
		for placement in rubyPlacements(stroke: nil) {
			let path = CTLineGetBoundsWithOptions(placement.line, [.useGlyphPathBounds])
			guard !path.isNull, !path.isEmpty else { continue }
			union = union.union(path.applying(placement.transform).insetBy(dx: -rubyOutset, dy: -rubyOutset))
		}
		// 縦中横 (slice-4 PR-2): union each group's mini-line ink at its cell —
		// keyed off the group derivation, NOT line bounds (a group-only column
		// is a line whose visible content is only the mini-line; the original
		// glyph paths are suppressed ink that may or may not register). The
		// outline outset mirrors the base-run treatment.
		let tcyOutset = activeOutline?.width ?? 0
		let ns = attributedString.string as NSString
		for group in currentTateChuYokoGroups() {
			guard let cell = tateChuYokoCell(for: group) else { continue }
			let baseAttributes = attributedString.attributes(at: group.location, effectiveRange: nil)
			let mini = PorticoTateChuYoko.miniLine(
				groupText: ns.substring(with: group),
				baseAttributes: baseAttributes,
				cellCross: cell.width,
				stroke: nil)
			// GLYPH-PATH bounds (baseline-relative), not typographic — the
			// rest of the union is path-tight and the tightness pin holds
			// ink to painted pixels.
			let pathBounds = CTLineGetBoundsWithOptions(mini.line, [.useGlyphPathBounds])
			guard !pathBounds.isNull, !pathBounds.isEmpty else { continue }
			let drawX = cell.midX - mini.width / 2
			let baseline = cell.midY - (mini.ascent - mini.descent) / 2
			let inkRect = CGRect(
				x: drawX + pathBounds.minX,
				y: baseline + pathBounds.minY,
				width: pathBounds.width,
				height: pathBounds.height
			).insetBy(dx: -tcyOutset, dy: -tcyOutset)
			union = union.union(inkRect)
		}

		return union
	}
	
	private func drawSelection(in context: CGContext) {
		guard let selectionRange = selectionRange else { return }
		context.setFillColor(CGColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 0.3))
		for rect in selectionRects(for: selectionRange) {
			context.fill(rect)
		}
	}
	
	/// The text itself — the one place glyphs hit the context. CoreText natively handles
	/// vertical layout geometry when progression is rightToLeft and
	/// kCTVerticalFormsAttributeName is applied. No context rotation needed on macOS!
	/// When an outline is set, the stroke pass paints first (behind the fill) with a
	/// round join — the default miter join spikes at sharp glyph corners, exactly the
	/// manga-fuchi failure mode.
	private func drawTextCore(in context: CGContext) {
		guard let textFrame = textFrame else { return }
		if let strokeFrame = currentStrokeFrame() {
			context.saveGState()
			context.setLineJoin(.round)
			context.setLineCap(.round)
			CTFrameDraw(strokeFrame, context)
			// 縦中横 stroke pass rides with the base stroke frame (all strokes
			// behind all fills — layering parity with the base text).
			drawTateChuYoko(in: context, stroke: activeOutline)
			drawRuby(in: context, stroke: activeOutline)
			context.restoreGState()
		}
		CTFrameDraw(textFrame, context)
		drawTateChuYoko(in: context, stroke: nil)
		drawRuby(in: context, stroke: nil)
	}

	// MARK: - Ruby drawn by Portico (ruby-typesetting arc, 2026-09-25)

	/// Where each reading is drawn: a small line CENTRED on its base word along the writing
	/// direction, sitting just outside the base glyph box on the ruby side (right of a vertical
	/// column, above a horizontal line). ⭐ The base is laid out as if the ruby were absent, so a
	/// long reading simply OVERSHOOTS or OVERLAPS its neighbours — the artist's rule; nothing moves.
	/// A word split across lines (longer than the inline limit) gets its reading over the first part.
	/// `transform` maps the ruby line's own space into engine (bottom-left) coordinates.
	func rubyPlacements(stroke: PorticoTextOutline?) -> [(line: CTLine, transform: CGAffineTransform)] {
		guard let textFrame else { return [] }
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return [] }
		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)
		var placements: [(line: CTLine, transform: CGAffineTransform)] = []
		for group in PorticoRuby.rubyGroups(in: NSRange(location: 0, length: attributedString.length), of: attributedString) {
			guard let index = lines.firstIndex(where: {
				let r = CTLineGetStringRange($0)
				return group.base.location >= r.location && group.base.location < r.location + r.length
			}) else { continue }
			let line = lines[index], origin = origins[index]
			let lineRange = CTLineGetStringRange(line)
			let end = min(group.base.location + group.base.length, lineRange.location + lineRange.length)
			let start = CTLineGetOffsetForStringIndex(line, group.base.location, nil)
			let stop = CTLineGetOffsetForStringIndex(line, end, nil)
			// The base glyph box's ruby-side edge, from the WORD's own glyphs — NOT the laid-out
			// line, whose typographic ascent the fixed line height inflates (vertical text drew its
			// ruby about an em too far out). Vertical glyphs are centred on the baseline: ±½ em.
			let ascent = baseGlyphAscent(of: group.base)
			guard let ruby = rubyLine(for: group, stroke: stroke) else { continue }
			var rubyAscent: CGFloat = 0, rubyDescent: CGFloat = 0
			let rubyWidth = CGFloat(CTLineGetTypographicBounds(ruby, &rubyAscent, &rubyDescent, nil))
			// Line-local: x along the advance, y across it (ascent side positive).
			let local = CGAffineTransform(
				translationX: (start + stop) / 2 - rubyWidth / 2, y: ascent + rubyDescent)
			let toEngine = orientation == .vertical
				? CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: origin.x, ty: origin.y)
				: CGAffineTransform(translationX: origin.x, y: origin.y)
			placements.append((ruby, local.concatenating(toEngine)))
		}
		return placements
	}

	/// A reading as its own line: the base's attributes at the group, the font scaled by the
	/// annotation's size factor (half by default), vertical forms in vertical text; `stroke`
	/// adds the outline so the rim matches the base's ABSOLUTE width.
	private func rubyLine(for group: (base: NSRange, reading: String), stroke: PorticoTextOutline?) -> CTLine? {
		guard !group.reading.isEmpty, group.base.location < attributedString.length else { return nil }
		var attributes = attributedString.attributes(at: group.base.location, effectiveRange: nil)
		let annotation = attributes[PorticoRuby.rubyKey]
		for key in [PorticoRuby.rubyKey, .paragraphStyle, PorticoTateChuYoko.groupKey,
		            NSAttributedString.Key(kCTRunDelegateAttributeName as String)] {
			attributes.removeValue(forKey: key)
		}
		var factor: CGFloat = 0.5
		if let annotation, CFGetTypeID(annotation as CFTypeRef) == CTRubyAnnotationGetTypeID() {
			let f = CTRubyAnnotationGetSizeFactor(annotation as! CTRubyAnnotation)
			if f > 0 { factor = f }
		}
		let baseSize = Self.pointSize(ofFontAttribute: attributes[.font])
		let rubySize = baseSize * factor
		if let value = attributes[.font], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() {
			attributes[.font] = CTFontCreateCopyWithAttributes(value as! CTFont, rubySize, nil, nil)
		} else {
			attributes[.font] = CTFontCreateUIFontForLanguage(.system, rubySize, nil)
		}
		if orientation == .vertical { attributes[.verticalGlyphForm] = true }
		if let stroke {
			attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
				((2 * stroke.width) / rubySize * 100) as NSNumber
			attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = stroke.color
		}
		return CTLineCreateWithAttributedString(NSAttributedString(string: group.reading, attributes: attributes))
	}

	private func drawRuby(in context: CGContext, stroke: PorticoTextOutline?) {
		for placement in rubyPlacements(stroke: stroke) {
			context.saveGState()
			context.concatenate(placement.transform)
			context.textMatrix = .identity
			context.textPosition = .zero
			CTLineDraw(placement.line, context)
			context.restoreGState()
		}
	}

	/// 縦中横 groups in the CURRENT text (ruby ranges excluded) — the same
	/// pure derivation the reservation uses; shared by draw + inkBounds.
	private func currentTateChuYokoGroups() -> [NSRange] {
		guard orientation == .vertical else { return [] }
		return PorticoTateChuYoko.effectiveGroups(in: attributedString)
	}

	/// The 縦中横 cell in engine (bottom-left) coordinates, derived WITHIN
	/// the group's own line (same offset/origin formulas as `caretRect`).
	/// PR-3 finding: the earlier two-caret derivation misread a column
	/// break landing right AFTER a group as a split — `caretRect(for:
	/// groupEnd)` resolves to the NEXT line's head at that boundary, and
	/// the mini-line silently skipped (the forbidden blank-cell class).
	/// Both offsets computed against the line CONTAINING the group are
	/// boundary-safe. Nil only for a TRUE split (the group's characters on
	/// different lines) or no layout.
	func tateChuYokoCell(for group: NSRange) -> CGRect? {
		guard orientation == .vertical, let textFrame = textFrame else { return nil }
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return nil }
		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)

		for (line, origin) in zip(lines, origins) {
			let range = CTLineGetStringRange(line)
			guard group.location >= range.location,
			      group.location < range.location + range.length else { continue }
			guard group.location + group.length <= range.location + range.length else {
				return nil // TRUE split: the pair's characters are on different lines
			}
			var ascent: CGFloat = 0
			var descent: CGFloat = 0
			var leading: CGFloat = 0
			CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
			let startOffset = CTLineGetOffsetForStringIndex(line, group.location, nil)
			let endOffset = CTLineGetOffsetForStringIndex(line, group.location + group.length, nil)
			let top = origin.y - startOffset
			let bottom = origin.y - endOffset
			guard top > bottom else { return nil }
			return CGRect(x: origin.x - descent, y: bottom, width: ascent + descent, height: top - bottom)
		}
		return nil
	}

	/// Draw each group's upright mini-line centered in its cell. `stroke`
	/// non-nil = the stroke pass (called under the round-join state).
	private func drawTateChuYoko(in context: CGContext, stroke: PorticoTextOutline?) {
		let groups = currentTateChuYokoGroups()
		guard !groups.isEmpty else { return }
		let ns = attributedString.string as NSString
		for group in groups {
			guard let cell = tateChuYokoCell(for: group) else { continue }
			let baseAttributes = attributedString.length > group.location
				? attributedString.attributes(at: group.location, effectiveRange: nil)
				: typingAttributes
			let mini = PorticoTateChuYoko.miniLine(
				groupText: ns.substring(with: group),
				baseAttributes: baseAttributes,
				cellCross: cell.width,
				stroke: stroke)
			context.saveGState()
			context.textMatrix = .identity
			let x = cell.midX - mini.width / 2
			let baseline = cell.midY - (mini.ascent - mini.descent) / 2
			context.textPosition = CGPoint(x: x, y: baseline)
			CTLineDraw(mini.line, context)
			context.restoreGState()
		}
	}

	/// The caret, when the engine owns it (see `drawsCaret`). Drawn over the text.
	private func drawCaret(in context: CGContext) {
		guard drawsCaret && selectionRange == nil && markedRange == nil else { return }
		let rect = caretRect(for: cursorIndex)
		context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
		context.fill(rect)
	}

	/// Editing render: selection highlight under the text, caret over it.
	public func draw(in context: CGContext) {
		guard textFrame != nil else { return }

		context.saveGState()

		// Draw selection highlight first so text is drawn over it
		if drawsSelectionHighlight {
			drawSelection(in: context)
		}

		drawTextCore(in: context)

		drawCaret(in: context)

		context.restoreGState()
	}

	/// Renders the laid-out text only — no selection highlight, no caret. The
	/// display/raster-export counterpart of `draw(in:)`: use this to paint a committed,
	/// non-editing document (a canvas element, a thumbnail, a high-DPI export tile);
	/// output is independent of `cursorIndex`/`selectionRange` state. No layout
	/// (zero `bounds`) = no-op.
	public func drawText(in context: CGContext) {
		guard textFrame != nil else { return }
		context.saveGState()
		drawTextCore(in: context)
		context.restoreGState()
	}
}
