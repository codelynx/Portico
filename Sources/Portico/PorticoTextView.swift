import Foundation

#if os(macOS)
import AppKit

public class PorticoTextView: NSView, NSMenuItemValidation {
	public let layoutEngine: PorticoTextLayoutEngine

	/// Optional client-supplied selection action (design §7.2 seam). When set, a menu item
	/// titled `title` is added to the right-click context menu whenever there's a non-empty
	/// selection; choosing it calls `handler` with the current selection range and its
	/// first-segment anchor rect (top-left view coords). `nil` → no item (opt-out default). The
	/// framework owns the menu plumbing; the label + whatever UI the handler shows are the
	/// client's (e.g. a ruby-reading popover).
	public var onSelectionMenuAction: PorticoSelectionMenuAction?

	public init(frame: NSRect, layoutEngine: PorticoTextLayoutEngine) {
		self.layoutEngine = layoutEngine
		super.init(frame: frame)
		// Repaint on engine-driven changes the view didn't initiate — undo/redo, client setRuby,
		// external edits. Weak self: the engine may outlive the view (client-owned, injected).
		layoutEngine.onNeedsDisplay = { [weak self] in self?.needsDisplay = true }
	}
	
	public required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
	
	public override var isFlipped: Bool { return false }
	public override var acceptsFirstResponder: Bool { return true }

	/// When `true`, the view claims first responder as soon as it lands in a
	/// window — for hosts that mount the editor programmatically (an in-place
	/// overlay opened by a tool gesture) rather than via a user click on the
	/// view itself. One-shot per attach; a later re-attach re-claims only if
	/// still set. Default `false`: plain embeds keep click-to-focus.
	public var focusesOnMount: Bool = false

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard focusesOnMount, let window else { return }
		window.makeFirstResponder(self)
	}

	/// Vend the engine's undo manager up the responder chain, so Edit ▸ Undo/Redo and ⌘Z drive the
	/// engine's model-scoped stack (§1) — but **`nil` while composing** (marked text active), which
	/// greys out the menu *and* blocks ⌘Z: every system entry point resolves through this property,
	/// so undoing mid-composition (which would desync the IME) is impossible. Registration is
	/// unaffected — the engine holds its manager directly.
	public override var undoManager: UndoManager? {
		layoutEngine.markedRange == nil ? layoutEngine.undoManager : nil
	}
	
	public override func draw(_ dirtyRect: NSRect) {
		super.draw(dirtyRect)
		guard let context = NSGraphicsContext.current?.cgContext else { return }
		layoutEngine.update(bounds: bounds.size)
		layoutEngine.draw(in: context)
	}
	
	public override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		let point = convert(event.locationInWindow, from: nil)
		let index = layoutEngine.stringIndex(for: point)
		if event.clickCount == 2, let word = layoutEngine.wordRange(at: index) {
			layoutEngine.setSelectedRange(word) // double-click selects the whole word
		} else {
			layoutEngine.beginSelection(at: index)
		}
		setNeedsDisplay(bounds)
	}
	
	public override func mouseDragged(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		let index = layoutEngine.stringIndex(for: point)
		layoutEngine.updateSelection(to: index)
		setNeedsDisplay(bounds)
	}
	
	public override func keyDown(with event: NSEvent) {
		guard let inputContext = self.inputContext else {
			super.keyDown(with: event)
			return
		}
		if !inputContext.handleEvent(event) {
			if event.characters == "\u{7F}" {
				layoutEngine.deleteBackward()
				setNeedsDisplay(bounds)
			} else {
				super.keyDown(with: event)
			}
		}
	}
	
	public override func doCommand(by selector: Selector) {
		if selector == #selector(deleteBackward(_:)) {
			layoutEngine.deleteBackward()
			setNeedsDisplay(bounds)
		} else if selector == #selector(moveLeft(_:)) {
			layoutEngine.moveCursor(direction: .left)
			setNeedsDisplay(bounds)
		} else if selector == #selector(moveRight(_:)) {
			layoutEngine.moveCursor(direction: .right)
			setNeedsDisplay(bounds)
		} else if selector == #selector(moveUp(_:)) {
			layoutEngine.moveCursor(direction: .up)
			setNeedsDisplay(bounds)
		} else if selector == #selector(moveDown(_:)) {
			layoutEngine.moveCursor(direction: .down)
			setNeedsDisplay(bounds)
		} else if selector == #selector(moveLeftAndModifySelection(_:)) {
			layoutEngine.moveCursor(direction: .left, modifySelection: true)
			setNeedsDisplay(bounds)
		} else if selector == #selector(moveRightAndModifySelection(_:)) {
			layoutEngine.moveCursor(direction: .right, modifySelection: true)
			setNeedsDisplay(bounds)
		} else if selector == #selector(moveUpAndModifySelection(_:)) {
			layoutEngine.moveCursor(direction: .up, modifySelection: true)
			setNeedsDisplay(bounds)
		} else if selector == #selector(moveDownAndModifySelection(_:)) {
			layoutEngine.moveCursor(direction: .down, modifySelection: true)
			setNeedsDisplay(bounds)
		} else if responds(to: selector) {
			perform(selector)
		}
	}

	// MARK: - Context menu + clipboard (design §7.2 seam)
	// macOS has no automatic clipboard for NSTextInputClient (unlike iOS's UITextInteraction), so
	// Cut/Copy/Paste/Delete/Select All are implemented here as responder actions. This also lights
	// up the app's Edit menu and ⌘X/⌘C/⌘V/⌘A (all routed through the responder chain to this first
	// responder). Undo/Redo is vended from the engine's UndoManager — see the `undoManager` override.

	/// Right-click shows the standard editing items, plus the client's selection action (e.g.
	/// Ruby…) when a selection exists and the seam is set.
	public override func menu(for event: NSEvent) -> NSMenu? {
		let menu = NSMenu()
		menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "").target = self
		menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
		menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "").target = self
		if let action = onSelectionMenuAction, (layoutEngine.selectionRange?.length ?? 0) > 0 {
			menu.addItem(.separator())
			let item = NSMenuItem(title: action.title,
								  action: #selector(performSelectionMenuAction(_:)), keyEquivalent: "")
			item.target = self
			menu.addItem(item)
		}
		return menu
	}

	/// Target of both the context-menu item and any app main-menu command (e.g. `Edit ▸ Ruby…`)
	/// wired to this selector via the responder chain. Re-reads the selection at invocation time.
	@objc public func performSelectionMenuAction(_ sender: Any?) {
		guard let action = onSelectionMenuAction,
			  let selection = layoutEngine.selectionRange, selection.length > 0,
			  let anchor = layoutEngine.anchorRectForSelection() else { return }
		action.handler(selection, anchor)
	}

	/// Copy the selection to the pasteboard as Aozora notation, so ruby survives copy/paste.
	@objc public func copy(_ sender: Any?) {
		guard let notation = layoutEngine.serializedSelection() else { return }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(notation, forType: .string)
	}

	@objc public func cut(_ sender: Any?) {
		guard (layoutEngine.selectionRange?.length ?? 0) > 0 else { return }
		copy(sender)
		layoutEngine.deleteBackward() // deletes the current selection
		setNeedsDisplay(bounds)
	}

	@objc public func paste(_ sender: Any?) {
		guard let string = NSPasteboard.general.string(forType: .string) else { return }
		layoutEngine.insertNotation(string) // parses notation → ruby round-trips
		setNeedsDisplay(bounds)
	}

	@objc public func delete(_ sender: Any?) {
		guard (layoutEngine.selectionRange?.length ?? 0) > 0 else { return }
		layoutEngine.deleteBackward()
		setNeedsDisplay(bounds)
	}

	@objc public override func selectAll(_ sender: Any?) {
		layoutEngine.setSelectedRange(NSRange(location: 0, length: layoutEngine.attributedString.length))
		setNeedsDisplay(bounds)
	}

	/// Validate both the app Edit menu (routed here as first responder) and our context menu:
	/// clipboard/delete need a selection, paste needs pasteboard text, select-all needs content,
	/// and the client action needs the seam plus a selection.
	public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		let hasSelection = (layoutEngine.selectionRange?.length ?? 0) > 0
		switch menuItem.action {
		case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)):
			return hasSelection
		case #selector(paste(_:)):
			return NSPasteboard.general.string(forType: .string) != nil
		case #selector(selectAll(_:)):
			return layoutEngine.attributedString.length > 0
		case #selector(performSelectionMenuAction(_:)):
			return onSelectionMenuAction != nil && hasSelection
		default:
			return true
		}
	}
}

extension PorticoTextView: @preconcurrency NSTextInputClient {
	public func insertText(_ string: Any, replacementRange: NSRange) {
		let textToInsert = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
		layoutEngine.insertText(textToInsert)
		setNeedsDisplay(bounds)
	}
	
	public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
		let textToInsert = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
		layoutEngine.setMarkedText(textToInsert, selectedRange: selectedRange, replacementRange: replacementRange)
		setNeedsDisplay(bounds)
	}
	
	public func unmarkText() {
		layoutEngine.unmarkText()
		setNeedsDisplay(bounds)
	}
	
	public func selectedRange() -> NSRange {
		// Report the active selection (not just the caret) so IME/services queries see the
		// real range the engine draws; collapse to a caret when there's no selection.
		if let sr = layoutEngine.selectionRange { return sr }
		return NSRange(location: layoutEngine.cursorIndex, length: 0)
	}
	
	public func markedRange() -> NSRange { 
		return layoutEngine.markedRange ?? NSRange(location: NSNotFound, length: 0) 
	}
	
	public func hasMarkedText() -> Bool { 
		return layoutEngine.markedRange != nil 
	}
	
	public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { return nil }
	
	public func validAttributesForMarkedText() -> [NSAttributedString.Key] { 
		return [NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] 
	}
	
	public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
		actualRange?.pointee = range
		let localRect = layoutEngine.rect(forCharacterRange: range)
		
		var adjustedRect = localRect
		if layoutEngine.orientation == .vertical {
			// In macOS coordinate space (bottom-up), maxY is visually the TOP of the rect.
			// maxX is visually the RIGHT edge.
			// The OS anchors the popup to the bottom-left of the provided NSRect.
			// By providing a 0x0 rect at the top-right of the character, the popup 
			// will appear to the right of the vertical column, avoiding obscuring the text!
			adjustedRect = CGRect(x: localRect.maxX, y: localRect.maxY, width: 0, height: 0)
		}
		
		let windowRect = convert(adjustedRect, to: nil)
		guard let window = self.window else { return .zero }
		return window.convertToScreen(windowRect)
	}
	public func characterIndex(for point: NSPoint) -> Int { return 0 }
}

#elseif os(iOS)
import UIKit

public class PorticoTextView: UIView, UITextInput {

	public let layoutEngine: PorticoTextLayoutEngine

	/// Optional client-supplied selection action (design §7.2 seam). When set, an item titled
	/// `title` is appended to the native selection edit menu (alongside Copy / Look Up) whenever
	/// there's a non-empty selection; choosing it calls `handler` with the current selection range
	/// and its first-segment anchor rect (top-left view coords). `nil` → no item (opt-out default).
	/// Added through `editMenu(for:suggestedActions:)` — the hook `UITextInteraction` already
	/// calls — so it augments the existing menu rather than installing a rival interaction.
	public var onSelectionMenuAction: PorticoSelectionMenuAction?

	public init(frame: CGRect, layoutEngine: PorticoTextLayoutEngine) {
		self.layoutEngine = layoutEngine
		super.init(frame: frame)
		self.backgroundColor = .clear
		self.contentMode = .redraw
		// Repaint on engine-driven changes the view didn't initiate — undo/redo, client setRuby.
		// Weak self: the engine may outlive the view (client-owned, injected).
		layoutEngine.onNeedsDisplay = { [weak self] in self?.setNeedsDisplay() }
		observeUndoForSelectionRefresh()

		// Let UIKit own selection UI: a UITextInteraction drives caret placement,
		// word/loupe selection, and grab handles through our UITextInput conformance
		// (closestPosition, selectionRects, selectedTextRange). The engine therefore
		// stops drawing its own selection fill to avoid doubling. (It still draws the
		// caret in vertical mode, where UIKit can't render one — see draw(in:).)
		// (addInteraction retains it via the view's `interactions` array.)
		layoutEngine.drawsSelectionHighlight = false
		let interaction = UITextInteraction(for: .editable)
		interaction.textInput = self
		addInteraction(interaction)
	}
	
	public required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private var undoObservers: [NSObjectProtocol] = []

	isolated deinit {
		undoObservers.forEach(NotificationCenter.default.removeObserver)
	}

	/// Bracket engine-external undo/redo (⌘Z / shake) so `UITextInteraction` refreshes its cached
	/// selection UI. The engine's `UndoManager` posts will/did notifications around each transition;
	/// we fire the `inputDelegate` will/did selection pair synchronously (queue `nil`) around them.
	/// Scoped to undo/redo only — the typing paths bracket themselves — avoiding the reentrancy that
	/// ruled out doing this from `onNeedsDisplay`. (With an injected host manager, this also fires on
	/// the host's *own* undo/redo — the notifications carry no target to filter on — but that's a
	/// harmless extra re-query, since nothing in our layout changed.)
	private func observeUndoForSelectionRefresh() {
		let manager = layoutEngine.undoManager
		func observe(_ name: Notification.Name, will: Bool) {
			let token = NotificationCenter.default.addObserver(forName: name, object: manager, queue: nil) { [weak self] _ in
				guard let self else { return }
				// Skip while composing: our own undo is blocked (vend-nil), but a *shared injected*
				// manager can fire for the host's own undo/redo — don't poke the IME mid-composition.
				guard self.layoutEngine.markedRange == nil else { return }
				if will {
					self.inputDelegate?.textWillChange(self)
					self.inputDelegate?.selectionWillChange(self)
				} else {
					self.inputDelegate?.selectionDidChange(self)
					self.inputDelegate?.textDidChange(self)
				}
			}
			undoObservers.append(token)
		}
		observe(.NSUndoManagerWillUndoChange, will: true)
		observe(.NSUndoManagerWillRedoChange, will: true)
		observe(.NSUndoManagerDidUndoChange, will: false)
		observe(.NSUndoManagerDidRedoChange, will: false)
	}

	public override var canBecomeFirstResponder: Bool { return true }

	/// When `true`, the view claims first responder as soon as it lands in a
	/// window — for hosts that mount the editor programmatically (an in-place
	/// overlay opened by a tool gesture) rather than via a user touch on the
	/// view itself. Default `false`: plain embeds keep tap-to-focus.
	public var focusesOnMount: Bool = false

	public override func didMoveToWindow() {
		super.didMoveToWindow()
		guard focusesOnMount, window != nil else { return }
		becomeFirstResponder()
	}

	/// Vend the engine's undo manager up the responder chain, so ⌘Z / shake-to-undo drive the
	/// engine's model-scoped stack (§1) — but **`nil` while composing** (marked text active), so
	/// undoing mid-composition (which would desync the IME) is blocked at every entry point.
	/// Registration is unaffected — the engine holds its manager directly.
	public override var undoManager: UndoManager? {
		layoutEngine.markedRange == nil ? layoutEngine.undoManager : nil
	}

	// Hardware arrow keys (and Shift+arrow selection) are driven by UITextInteraction through
	// UITextInput — `position(from:in:offset:)` / `characterRange(byExtending:in:)` — which route
	// to the engine's orientation-aware movement. An earlier `keyCommands` path was superseded by
	// that (UIKeyCommand yields to system text handling once UITextInteraction is installed).

	public override func layoutSubviews() {
		super.layoutSubviews()
		if layoutEngine.bounds != bounds.size {
			layoutEngine.update(bounds: bounds.size)
			setNeedsDisplay()
		}
	}

	private var caretTintCleared = false

	/// In vertical, the engine draws the caret (UIKit can't render a horizontal one and
	/// would show a stub). Hide UIKit's caret by clearing the view tint while there's no
	/// selection — leaving only the engine's caret — and restore it when a selection
	/// exists so native handles / edit menu keep their color. `caretRect` stays honest, so
	/// UIKit's cursor tracking (which the engine caret follows) is untouched.
	private func updateCaretTint() {
		let engineOwnsCaret = layoutEngine.orientation == .vertical
			&& layoutEngine.selectionRange == nil
			&& layoutEngine.markedRange == nil
		if engineOwnsCaret, !caretTintCleared {
			tintColor = .clear
			caretTintCleared = true
		} else if !engineOwnsCaret, caretTintCleared {
			tintColor = nil
			caretTintCleared = false
		}
	}

	public override func draw(_ rect: CGRect) {
		super.draw(rect)
		guard let context = UIGraphicsGetCurrentContext() else { return }
		layoutEngine.update(bounds: bounds.size)
		updateCaretTint()

		context.saveGState()
		context.translateBy(x: 0, y: bounds.height)
		context.scaleBy(x: 1.0, y: -1.0)
		layoutEngine.draw(in: context)
		context.restoreGState()
	}
	
	// MARK: - UIKeyInput overrides (already inherited by UITextInput)
	public var hasText: Bool { return layoutEngine.attributedString.length > 0 }

	/// Bracket an engine text mutation with the input-delegate notifications so UITextInteraction
	/// re-queries its cached geometry, then redraw. Text notifications fire **unconditionally** —
	/// the mutation may reshape text beyond a plain append (inline ruby conversion strips `《》｜`;
	/// a boundary insert strips a ruby annotation, changing line height with no length delta), so a
	/// pre-change "will it reshape?" predicate would be fragile; the cost is a benign spurious
	/// notify on plain typing. Selection notifications fire **only when the mutation replaced a
	/// selection**, so the now-stale grab handles are dismissed to a caret (plain typing pays
	/// nothing extra). Marked-text edits stay unbracketed — see setMarkedText.
	private func mutatingText(replacedSelection: Bool, _ mutate: () -> Void) {
		inputDelegate?.textWillChange(self)
		if replacedSelection { inputDelegate?.selectionWillChange(self) }
		mutate()
		if replacedSelection { inputDelegate?.selectionDidChange(self) }
		inputDelegate?.textDidChange(self)
		setNeedsDisplay()
	}

	public func insertText(_ text: String) {
		mutatingText(replacedSelection: (layoutEngine.selectionRange?.length ?? 0) > 0) {
			layoutEngine.insertText(text)
		}
	}
	public func deleteBackward() {
		// Grapheme-cluster–aware: deletes the selection when there is one, else one cluster back.
		mutatingText(replacedSelection: (layoutEngine.selectionRange?.length ?? 0) > 0) {
			layoutEngine.deleteBackward()
		}
	}

	// MARK: - Clipboard (UIResponderStandardEditActions)
	// UITextInteraction gates edit-menu items on canPerformAction + the responder implementing the
	// action; it doesn't supply Cut/Copy/Paste itself. Copy uses Aozora notation (like macOS), so
	// ruby round-trips copy/paste on iOS too.
	public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
		let hasSelection = (layoutEngine.selectionRange?.length ?? 0) > 0
		switch action {
		case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)):
			return hasSelection
		case #selector(paste(_:)):
			return UIPasteboard.general.hasStrings
		case #selector(selectAll(_:)):
			return layoutEngine.attributedString.length > 0
		default:
			return super.canPerformAction(action, withSender: sender)
		}
	}

	public override func copy(_ sender: Any?) {
		guard let notation = layoutEngine.serializedSelection() else { return }
		UIPasteboard.general.string = notation
	}

	public override func cut(_ sender: Any?) {
		guard (layoutEngine.selectionRange?.length ?? 0) > 0 else { return }
		copy(sender)
		mutatingText(replacedSelection: true) { layoutEngine.deleteBackward() } // deletes the selection
	}

	public override func paste(_ sender: Any?) {
		guard let string = UIPasteboard.general.string else { return }
		mutatingText(replacedSelection: (layoutEngine.selectionRange?.length ?? 0) > 0) {
			layoutEngine.insertNotation(string) // parses notation → ruby round-trips
		}
	}

	public override func delete(_ sender: Any?) {
		guard (layoutEngine.selectionRange?.length ?? 0) > 0 else { return }
		mutatingText(replacedSelection: true) { layoutEngine.deleteBackward() } // deletes the selection
	}

	public override func selectAll(_ sender: Any?) {
		inputDelegate?.selectionWillChange(self)
		layoutEngine.setSelectedRange(NSRange(location: 0, length: layoutEngine.attributedString.length))
		inputDelegate?.selectionDidChange(self)
		setNeedsDisplay()
	}

	// MARK: - Selection edit menu (design §7.2 seam)

	/// Augment the native selection menu with the client's action (iOS 16+). This is the hook
	/// `UITextInteraction` already calls, so we never install a competing menu interaction.
	/// Our action goes **first**, in its own inline group: since we implement the clipboard
	/// actions, `suggestedActions` is now the full Cut/Copy/Paste/Look Up/Translate/… list, and
	/// appending our item would bury it below the fold on the long iOS edit menu.
	public func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
		guard let action = onSelectionMenuAction,
			  let selection = layoutEngine.selectionRange, selection.length > 0 else {
			return nil // nil presents the default system menu unchanged (SDK contract)
		}
		let item = UIAction(title: action.title) { [weak self] _ in
			guard let self,
				  let sel = self.layoutEngine.selectionRange, sel.length > 0,
				  let anchor = self.layoutEngine.anchorRectForSelection() else { return }
			action.handler(sel, anchor)
		}
		let ours = UIMenu(title: "", options: .displayInline, children: [item])
		return UIMenu(children: [ours] + suggestedActions)
	}

	// MARK: - UITextInput
	public func text(in range: UITextRange) -> String? {
		guard let r = (range as? PorticoTextRange)?.range else { return nil }
		return (layoutEngine.attributedString.string as NSString).substring(with: r)
	}

	public func replace(_ range: UITextRange, withText text: String) {
		guard let r = (range as? PorticoTextRange)?.range else { return }
		// Route through setSelectedRange (not a raw `selectionRange = r`): a zero-length `r`
		// (UIKit sends these for QuickType / point insertions) must target its *location*, but the
		// setter normalizes zero-length to nil — setSelectedRange moves the caret to `r.location`
		// so insertText inserts there instead of at the old cursor.
		mutatingText(replacedSelection: r.length > 0) {
			layoutEngine.setSelectedRange(r)
			layoutEngine.insertText(text)
		}
	}

	public var selectedTextRange: UITextRange? {
		get {
			if let sr = layoutEngine.selectionRange {
				return PorticoTextRange(range: sr)
			}
			return PorticoTextRange(range: NSRange(location: layoutEngine.cursorIndex, length: 0))
		}
		set {
			if let r = (newValue as? PorticoTextRange)?.range {
				// Route through the engine so the selection anchor stays consistent —
				// otherwise a Shift+Arrow after a UIKit-created selection can't extend.
				layoutEngine.setSelectedRange(r)
				setNeedsDisplay()
			}
		}
	}

	public var markedTextRange: UITextRange? {
		if let mr = layoutEngine.markedRange { return PorticoTextRange(range: mr) }
		return nil
	}

	public var markedTextStyle: [NSAttributedString.Key : Any]? {
		get { return [.underlineStyle: NSUnderlineStyle.single.rawValue] }
		set { }
	}

	public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
		let textToInsert = markedText ?? ""
		layoutEngine.setMarkedText(textToInsert, selectedRange: selectedRange, replacementRange: nil)
		setNeedsDisplay()
	}

	public func unmarkText() {
		layoutEngine.unmarkText()
		setNeedsDisplay()
	}

	public var beginningOfDocument: UITextPosition { return PorticoTextPosition(index: 0) }
	public var endOfDocument: UITextPosition { return PorticoTextPosition(index: layoutEngine.attributedString.length) }

	public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
		guard let start = (fromPosition as? PorticoTextPosition)?.index,
			  let end = (toPosition as? PorticoTextPosition)?.index else { return nil }
		let range = NSRange(location: min(start, end), length: abs(end - start))
		return PorticoTextRange(range: range)
	}

	public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
		guard let p = (position as? PorticoTextPosition)?.index else { return nil }
		let newPos = p + offset
		if newPos < 0 || newPos > layoutEngine.attributedString.length { return nil }
		return PorticoTextPosition(index: newPos)
	}

	// Layout-direction navigation: UITextInteraction drives hardware arrows (and shifted-arrow
	// selection) through these, not through our keyCommands. Route them to the engine's
	// orientation-aware movement so `.up`/`.down` step by line (horizontal) and `.left`/`.right`
	// step by column (vertical RTL) — a naïve character offset would make up≡left, down≡right.
	public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
		guard let p = (position as? PorticoTextPosition)?.index else { return nil }
		// UIKit may query from a position left stale by an edit — clamp into bounds.
		let start = max(0, min(p, layoutEngine.attributedString.length))
		if offset == 0 { return PorticoTextPosition(index: start) }
		// A negative offset moves the opposite way; normalize to a positive step count.
		let dir = offset < 0 ? Self.opposite(direction) : direction
		var idx = start
		// Step one engine move at a time — line/column moves are NOT linear UTF-16 offsets, so
		// this can't be `start + offset`; each step recomputes from the new caret position.
		for _ in 0..<abs(offset) {
			idx = layoutEngine.index(from: idx, moving: Self.moveDirection(for: dir))
		}
		return PorticoTextPosition(index: idx)
	}

	public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? { return nil }

	public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
		guard let p = (position as? PorticoTextPosition)?.index else { return nil }
		let start = max(0, min(p, layoutEngine.attributedString.length))
		let moved = layoutEngine.index(from: start, moving: Self.moveDirection(for: direction))
		let lo = min(start, moved), hi = max(start, moved)
		return PorticoTextRange(range: NSRange(location: lo, length: hi - lo))
	}

	private static func moveDirection(for d: UITextLayoutDirection) -> PorticoTextLayoutEngine.MoveDirection {
		switch d {
		case .left: return .left
		case .right: return .right
		case .up: return .up
		case .down: return .down
		@unknown default: return .right
		}
	}

	private static func opposite(_ d: UITextLayoutDirection) -> UITextLayoutDirection {
		switch d {
		case .left: return .right
		case .right: return .left
		case .up: return .down
		case .down: return .up
		@unknown default: return d
		}
	}

	public var inputDelegate: UITextInputDelegate?

	public lazy var tokenizer: UITextInputTokenizer = {
		return UITextInputStringTokenizer(textInput: self)
	}()

	// MARK: Geometry/Layout
	public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { return .leftToRight }
	public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

	public func firstRect(for textRange: UITextRange) -> CGRect {
		guard let r = (textRange as? PorticoTextRange)?.range else { return .zero }
		let localRect = layoutEngine.rect(forCharacterRange: r)
		// Flip Y for UIKit
		return CGRect(x: localRect.origin.x, y: bounds.height - localRect.maxY, width: localRect.width, height: localRect.height)
	}

	public func caretRect(for position: UITextPosition) -> CGRect {
		guard let p = (position as? PorticoTextPosition)?.index else { return .zero }
		let localRect = layoutEngine.caretRect(for: p)
		// Honest rect always — UIKit needs it for cursor tracking (which the engine caret
		// follows), not just drawing. In vertical, UIKit's own caret is hidden via tint
		// (see updateCaretTint), not by degenerating this rect.
		return CGRect(x: localRect.origin.x, y: bounds.height - localRect.maxY, width: localRect.width, height: localRect.height)
	}

	public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
		guard let r = (range as? PorticoTextRange)?.range, r.length > 0 else { return [] }
		let rects = layoutEngine.selectionRects(for: r)
		let isVertical = layoutEngine.orientation == .vertical
		return rects.enumerated().map { index, localRect in
			// Core Text (bottom-left) → UIKit (top-left), same flip as caretRect/firstRect.
			let flipped = CGRect(x: localRect.origin.x, y: bounds.height - localRect.maxY,
								 width: localRect.width, height: localRect.height)
			return PorticoTextSelectionRect(rect: flipped,
											containsStart: index == 0,
											containsEnd: index == rects.count - 1,
											isVertical: isVertical)
		}
	}

	public func closestPosition(to point: CGPoint) -> UITextPosition? {
		let ctPoint = CGPoint(x: point.x, y: bounds.height - point.y)
		let index = layoutEngine.stringIndex(for: ctPoint)
		return PorticoTextPosition(index: index)
	}

	public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { return closestPosition(to: point) }
	public func characterRange(at point: CGPoint) -> UITextRange? {
		// UIKit calls this for loupe/handle placement — return the character containing
		// the point as a non-empty [start, start+1) range. At the document end, anchor
		// on the last character so it isn't empty; empty document yields a caret range.
		let length = layoutEngine.attributedString.length
		guard length > 0 else { return PorticoTextRange(range: NSRange(location: 0, length: 0)) }
		let ctPoint = CGPoint(x: point.x, y: bounds.height - point.y)
		let index = layoutEngine.stringIndex(for: ctPoint)
		let start = min(index, length - 1)
		return PorticoTextRange(range: NSRange(location: start, length: 1))
	}

	// MARK: Comparisons
	public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
		guard let p1 = (position as? PorticoTextPosition)?.index,
			  let p2 = (other as? PorticoTextPosition)?.index else { return .orderedSame }
		if p1 < p2 { return .orderedAscending }
		if p1 > p2 { return .orderedDescending }
		return .orderedSame
	}

	public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
		guard let p1 = (from as? PorticoTextPosition)?.index,
			  let p2 = (toPosition as? PorticoTextPosition)?.index else { return 0 }
		return p2 - p1
	}
}

public final class PorticoTextPosition: UITextPosition {
	public let index: Int
	public init(index: Int) { self.index = index }
}

public final class PorticoTextRange: UITextRange {
	public let range: NSRange
	public init(range: NSRange) { self.range = range }
	
	public override var start: UITextPosition { return PorticoTextPosition(index: range.location) }
	public override var end: UITextPosition { return PorticoTextPosition(index: range.location + range.length) }
	public override var isEmpty: Bool { return range.length == 0 }
}

/// Per-line selection geometry handed to UIKit through `UITextInput`. Supplies the
/// rects the `UITextInteraction` (installed in `init`) uses to render the native
/// selection handles / magnifier.
/// Internal: callers only ever see the abstract `[UITextSelectionRect]`.
final class PorticoTextSelectionRect: UITextSelectionRect {
	private let _rect: CGRect
	private let _containsStart: Bool
	private let _containsEnd: Bool
	private let _isVertical: Bool

	init(rect: CGRect, containsStart: Bool, containsEnd: Bool, isVertical: Bool) {
		self._rect = rect
		self._containsStart = containsStart
		self._containsEnd = containsEnd
		self._isVertical = isVertical
	}

	override var rect: CGRect { _rect }
	override var writingDirection: NSWritingDirection { .leftToRight }
	override var containsStart: Bool { _containsStart }
	override var containsEnd: Bool { _containsEnd }
	override var isVertical: Bool { _isVertical }
}
#endif
