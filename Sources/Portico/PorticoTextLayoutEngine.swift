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
		if target.location > 0, target.location - 1 < string.length {
			return string.attributes(at: target.location - 1, effectiveRange: nil)
		}
		let after = target.location + target.length
		if after < string.length {
			return string.attributes(at: after, effectiveRange: nil)
		}
		return typingAttributes
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
				let rect = caretRect(for: from)
				let point = CGPoint(x: rect.midX - rect.width, y: rect.midY)
				return stringIndex(for: point)
			}
		case .right:
			if orientation == .horizontal {
				return min(attributedString.length, from + 1)
			} else {
				let rect = caretRect(for: from)
				let point = CGPoint(x: rect.midX + rect.width, y: rect.midY)
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
		applyInlineRubyConversion()
	}

	// MARK: - Clipboard round-trip (backs macOS copy/cut/paste)
	// Ruby survives copy/paste by going through Aozora notation: Copy serializes the selection,
	// Paste parses it back. See Docs/RubyEditing-Design.md §7.2.

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

	/// The current selection serialized to Aozora notation (ruby preserved), or nil if there is no
	/// non-empty selection. Plain text serializes to itself (no marks).
	func serializedSelection() -> String? {
		guard let sr = selectionRange, sr.length > 0 else { return nil }
		return PorticoRuby.serialize(attributedString.attributedSubstring(from: sr))
	}

	/// Parse Aozora notation and insert it at the current target range (replacing any selection),
	/// giving the pasted text the insertion context's base attributes (font/colour) while keeping
	/// its parsed ruby annotations. Plain pasted text (no `《》`) inserts as plain text.
	func insertNotation(_ notation: String) {
		beginUndoStep() // paste is one discrete undo step
		let pasteTarget = markedRange ?? selectionRange ?? NSRange(location: cursorIndex, length: 0)
		var contextAttrs = inheritedAttributes(at: pasteTarget, in: attributedString)
		contextAttrs.removeValue(forKey: NSAttributedString.Key(kCTUnderlineStyleAttributeName as String))
		contextAttrs.removeValue(forKey: PorticoRuby.rubyKey)
		insertAttributedText(PorticoRuby.parse(notation, attributes: contextAttrs))
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
		return CTLineGetStringIndexForPosition(hit.line, hit.relativePoint)
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
		guard let textFrame = textFrame else { return .zero }
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return .zero }
		
		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)

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

	/// One fill rect per line that `range` intersects, in layout (Core Text,
	/// bottom-left origin) coordinates. Unlike `rect(forCharacterRange:)`, which
	/// returns only the first line, this spans a multi-line selection. Shared by the
	/// on-screen selection highlight and iOS `UITextInput.selectionRects(for:)`.
	public func selectionRects(for range: NSRange) -> [CGRect] {
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
	/// dependent, undefined for word-select / right-click). `selectionRects` yields one rect per
	/// line in document order, so its first element is exactly the first segment.
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

	/// Natural height of a line that carries one row of ruby, measured from a real
	/// CTLine using the string's own base attributes. Self-calibrating: it reflects
	/// the font Core Text actually uses (including CJK fallbacks) and the real ruby
	/// ascent, so no hand-tuned reserve ratio is needed.
	private func rubyLinePitch() -> CGFloat {
		var attrs = attributedString.length > 0
			? attributedString.attributes(at: 0, effectiveRange: nil)
			: typingAttributes
		attrs.removeValue(forKey: NSAttributedString.Key(kCTRubyAnnotationAttributeName as String))
		let sample = NSMutableAttributedString(string: "永", attributes: attrs) // representative CJK glyph
		let annotation = CTRubyAnnotationCreateWithAttributes(.center, .auto, .before, "ル" as CFString, [:] as CFDictionary)
		sample.addAttribute(
			NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
			value: annotation,
			range: NSRange(location: 0, length: 1)
		)
		let line = CTLineCreateWithAttributedString(sample as CFAttributedString)
		var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
		CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
		return ascent + descent + leading
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

	/// Scales the uniform ruby-reserving line pitch. 1.0 (default) = the standard
	/// ruby-sized pitch; < 1 tightens (ruby may overlap the previous line — the
	/// client's judgment); > 1 loosens. Clamped to [0.5, 3]; non-finite values are
	/// ignored. Setting a different value relayouts (and repaints a live view).
	/// Affects layout, `measuredSize`, and rendering identically — it feeds the one
	/// shared pitch. Note: in vertical orientation Core Text adds a small constant
	/// per-column leading on top of the pitch, so the multiplier scales the pitch
	/// term, not the absolute column advance.
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

	/// The pitch actually applied everywhere pitch matters (layout-string prep and
	/// the `measuredSize` block-extent floor) — the single source keeping the two
	/// consumption sites coherent.
	private var effectiveLinePitch: CGFloat { rubyLinePitch() * _linePitchMultiplier }

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

	/// The stroke-pass frame: the layout-ready string with CT stroke attributes
	/// (positive width = stroke-only) framed identically to `textFrame`. Lazily
	/// built and cached. Point width → percent-of-font-size conversion is per run
	/// (mixed sizes stroke correctly even though MangaLoft v1 styles are uniform);
	/// lineWidth = 2 × outline.width because CT centers strokes on the glyph path.
	private func currentStrokeFrame() -> CTFrame? {
		guard let o = activeOutline, textFrame != nil else { return nil }
		if let cached = strokeTextFrame { return cached }

		let strokeString = NSMutableAttributedString(attributedString: layoutReadyString())
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

		// R1 (verified by the rubyIsOutlined gate): CTRubyAnnotation glyphs do NOT
		// inherit the base run's stroke attributes — rebuild each annotation in the
		// stroke pass carrying stroke attributes of its own, sized so the reading
		// gets the same ABSOLUTE rim (percent is relative to the ruby font size =
		// size factor × base size). Alignment/overhang are copied from the source
		// annotation (today always center/auto — the single mint site — but copying
		// doesn't rot if PorticoRuby ever grows options).
		strokeString.enumerateAttribute(PorticoRuby.rubyKey, in: fullRange) { value, range, _ in
			guard let value else { return }
			// Foreign (non-CTRubyAnnotation) values under the ruby key are treated
			// as non-ruby everywhere else in Portico — the stroke pass must not trap
			// on them either.
			guard CFGetTypeID(value as CFTypeRef) == CTRubyAnnotationGetTypeID() else { return }
			let annotation = value as! CTRubyAnnotation
			let reading = CTRubyAnnotationGetTextForPosition(annotation, .before)
			guard let reading else { return }
			let baseSize = Self.pointSize(
				ofFontAttribute: strokeString.attribute(.font, at: range.location, effectiveRange: nil)
			)
			let sizeFactor = CTRubyAnnotationGetSizeFactor(annotation)
			let rubySize = baseSize * (sizeFactor > 0 ? sizeFactor : 0.5)
			let rubyPercent = (2 * o.width) / rubySize * 100
			let rubyAttributes: [CFString: Any] = [
				kCTStrokeWidthAttributeName: rubyPercent as NSNumber,
				kCTStrokeColorAttributeName: o.color,
			]
			let strokeAnnotation = CTRubyAnnotationCreateWithAttributes(
				CTRubyAnnotationGetAlignment(annotation),
				CTRubyAnnotationGetOverhang(annotation),
				.before,
				reading,
				rubyAttributes as CFDictionary
			)
			strokeString.addAttribute(PorticoRuby.rubyKey, value: strokeAnnotation, range: range)
		}

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
	private func layoutReadyString() -> NSAttributedString {
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		let fullRange = NSRange(location: 0, length: mutableString.length)

		// Reserve a uniform line-to-line pitch large enough to hold ruby on every
		// line, so lines stay evenly spaced whether or not they carry ruby (no
		// デコボコ). Merge it into any caller-supplied paragraph style rather than
		// overwriting, so alignment / indents / spacing survive.
		let pitch = effectiveLinePitch
		var styleUpdates: [(NSRange, NSParagraphStyle)] = []
		mutableString.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
			let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
			style.minimumLineHeight = pitch
			style.maximumLineHeight = pitch
			styleUpdates.append((range, style))
		}
		for (range, style) in styleUpdates {
			mutableString.addAttribute(.paragraphStyle, value: style, range: range)
		}

		if orientation == .vertical {
			// .verticalGlyphForm allows Core Text to substitute vertical variants of characters if the font supports it.
			mutableString.addAttribute(.verticalGlyphForm, value: true, range: fullRange)
			// 縦中横 (slice 4): reserve one column cell per auto-detected group
			// — on the LAYOUT COPY only (the backing store never carries the
			// delegate/marker; typing inheritance and Aozora serialization
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

		let setter = CTFramesetterCreateWithAttributedString(layoutReadyString() as CFAttributedString)
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
		let setter = CTFramesetterCreateWithAttributedString(layoutReadyString() as CFAttributedString)
		// Generous-but-finite bound for unconstrained axes: CGFloat.greatestFiniteMagnitude
		// is known to make CTFramesetterSuggestFrameSizeWithConstraints misbehave.
		let unbounded: CGFloat = 1_000_000
		// Non-finite or non-positive constraints are treated as unconstrained.
		let extent: CGFloat? = inlineExtent.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
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

	/// Typographic advance width of a ruby reading at ruby scale (Core Text's
	/// default 0.5 × the base font size). Used by `inkBounds()` to account for
	/// reading overhang past a line edge. Falls back to a per-character
	/// approximation when the base run carries no font (CT default metrics).
	private static func rubyReadingTypographicWidth(
		_ reading: String,
		baseAttributes: [NSAttributedString.Key: Any]
	) -> CGFloat {
		// Resolve the base font DEFENSIVELY: a foreign value under `.font`
		// (Portico tolerates foreign values under its own ruby key; be equally
		// tolerant here) must degrade to the approximation, never trap.
		let baseFont: CTFont?
		if let value = baseAttributes[.font],
		   CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() {
			// Covers CTFont AND platform fonts (NSFont/UIFont are toll-free
			// bridged, so their CFTypeID IS CTFontGetTypeID()).
			baseFont = (value as! CTFont)
		} else {
			baseFont = nil
		}
		let baseSize = baseFont.map(CTFontGetSize) ?? 12
		let rubySize = baseSize * 0.5
		guard let baseFont else {
			// No usable font: kana-monospace approximation.
			return CGFloat(reading.utf16.count) * rubySize
		}
		let rubyFont = CTFontCreateCopyWithAttributes(baseFont, rubySize, nil, nil)
		let attributed = NSAttributedString(string: reading, attributes: [
			NSAttributedString.Key(kCTFontAttributeName as String): rubyFont
		])
		let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
		return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
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

			// LINE-EDGE ruby overhang: glyph-path line bounds include ruby
			// glyphs, but a reading WIDER than its base overhangs the base's
			// advance span — and past the line's FIRST/LAST advance that
			// overhang is painted yet excluded from the line bounds (observed:
			// line-final long reading in vertical; caught by the MangaLoft
			// integration containment test). Extend the line-local advance
			// range by each intersecting group's reading overhang. Extending
			// mid-line groups too is harmless (their neighbors' ink already
			// unions wider).
			let lineRange = CTLineGetStringRange(line)
			let nsLineRange = NSRange(location: lineRange.location, length: lineRange.length)
			for group in PorticoRuby.rubyGroups(in: nsLineRange, of: attributedString) {
				let start = CTLineGetOffsetForStringIndex(line, group.base.location, nil)
				let end = CTLineGetOffsetForStringIndex(line, group.base.location + group.base.length, nil)
				let baseSpan = abs(end - start)
				let readingWidth = Self.rubyReadingTypographicWidth(
					group.reading,
					baseAttributes: attributedString.length > group.base.location
						? attributedString.attributes(at: group.base.location, effectiveRange: nil)
						: [:]
				)
				let overhang = max(0, (readingWidth - baseSpan) / 2)
				guard overhang > 0 else { continue }
				local = local.union(CGRect(
					x: min(start, end) - overhang,
					y: local.minY,
					width: baseSpan + overhang * 2,
					height: local.height
				))
			}

			union = union.union(lineLocalToEngineRect(local, lineOrigin: origin))
		}
		// The outline's rim extends exactly `width` past the glyph edge (stroke
		// lineWidth is 2 × width, centered on the path).
		if !union.isNull, let o = activeOutline {
			union = union.insetBy(dx: -o.width, dy: -o.width)
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
			context.restoreGState()
		}
		CTFrameDraw(textFrame, context)
		drawTateChuYoko(in: context, stroke: nil)
	}

	/// 縦中横 groups in the CURRENT text (ruby ranges excluded) — the same
	/// pure derivation the reservation uses; shared by draw + inkBounds.
	private func currentTateChuYokoGroups() -> [NSRange] {
		guard orientation == .vertical else { return [] }
		return PorticoTateChuYoko.groups(
			in: attributedString.string,
			excluding: PorticoTateChuYoko.genuineRubyRanges(in: attributedString))
	}

	/// The 縦中横 cell in engine (bottom-left) coordinates, derived from the
	/// PROVEN caret geometry (PR-1 pins) rather than re-deriving run
	/// positions. Nil when the group split across columns (wrap boundary —
	/// PR-3 territory) or has no layout.
	private func tateChuYokoCell(for group: NSRange) -> CGRect? {
		let startRect = caretRect(for: group.location)
		let endRect = caretRect(for: group.location + group.length)
		guard startRect != .zero, endRect != .zero,
		      abs(startRect.minX - endRect.minX) < 0.5 // same column
		else { return nil }
		let top = startRect.maxY
		let bottom = endRect.maxY
		guard top > bottom else { return nil }
		return CGRect(x: startRect.minX, y: bottom, width: startRect.width, height: top - bottom)
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
