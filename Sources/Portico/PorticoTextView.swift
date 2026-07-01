import Foundation

#if os(macOS)
import AppKit

public class PorticoTextView: NSView {
	public let layoutEngine: PorticoTextLayoutEngine
	
	public init(frame: NSRect, layoutEngine: PorticoTextLayoutEngine) {
		self.layoutEngine = layoutEngine
		super.init(frame: frame)
	}
	
	public required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
	
	public override var isFlipped: Bool { return false }
	public override var acceptsFirstResponder: Bool { return true }
	
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
		layoutEngine.beginSelection(at: index)
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
	
	public func selectedRange() -> NSRange { return NSRange(location: layoutEngine.cursorIndex, length: 0) }
	
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
	
	public init(frame: CGRect, layoutEngine: PorticoTextLayoutEngine) {
		self.layoutEngine = layoutEngine
		super.init(frame: frame)
		self.backgroundColor = .clear
		self.contentMode = .redraw

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
	
	public override var canBecomeFirstResponder: Bool { return true }

	// MARK: - Hardware keyboard navigation
	// Mirrors the macOS `doCommand(by:)` path: arrow keys move the caret, Shift+arrow
	// extends the selection. Both platforms funnel into the same engine call, so the
	// behavior stays identical. Scope matches macOS — arrows only, no word/line jumps.
	public override var keyCommands: [UIKeyCommand]? {
		let arrows = [
			UIKeyCommand.inputLeftArrow,
			UIKeyCommand.inputRightArrow,
			UIKeyCommand.inputUpArrow,
			UIKeyCommand.inputDownArrow,
		]
		return arrows.flatMap { input in
			[
				UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleMove(_:))),
				UIKeyCommand(input: input, modifierFlags: .shift, action: #selector(handleMove(_:))),
			]
		}
	}

	@objc private func handleMove(_ command: UIKeyCommand) {
		let direction: PorticoTextLayoutEngine.MoveDirection
		switch command.input {
		case UIKeyCommand.inputLeftArrow: direction = .left
		case UIKeyCommand.inputRightArrow: direction = .right
		case UIKeyCommand.inputUpArrow: direction = .up
		case UIKeyCommand.inputDownArrow: direction = .down
		default: return
		}
		let modifySelection = command.modifierFlags.contains(.shift)
		// Bracket the programmatic change so UIKit re-queries caretRect/selectedTextRange
		// and moves the native caret/selection; otherwise it stalls while the engine advances.
		inputDelegate?.selectionWillChange(self)
		layoutEngine.moveCursor(direction: direction, modifySelection: modifySelection)
		inputDelegate?.selectionDidChange(self)
		setNeedsDisplay()
	}

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
	public func insertText(_ text: String) {
		layoutEngine.insertText(text)
		setNeedsDisplay()
	}
	public func deleteBackward() {
		layoutEngine.deleteBackward()
		setNeedsDisplay()
	}

	// MARK: - UITextInput
	public func text(in range: UITextRange) -> String? {
		guard let r = (range as? PorticoTextRange)?.range else { return nil }
		return (layoutEngine.attributedString.string as NSString).substring(with: r)
	}

	public func replace(_ range: UITextRange, withText text: String) {
		guard let r = (range as? PorticoTextRange)?.range else { return }
		layoutEngine.selectionRange = r
		layoutEngine.insertText(text)
		setNeedsDisplay()
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

	public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
		guard let p = (position as? PorticoTextPosition)?.index else { return nil }
		let sign = (direction == .left || direction == .up) ? -1 : 1
		let newPos = p + (sign * offset)
		if newPos < 0 || newPos > layoutEngine.attributedString.length { return nil }
		return PorticoTextPosition(index: newPos)
	}

	public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? { return nil }
	public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? { return nil }

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
