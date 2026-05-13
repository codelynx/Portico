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
	
	public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { return .zero }
	public func characterIndex(for point: NSPoint) -> Int { return 0 }
}

#elseif os(iOS)
import UIKit

public class PorticoTextView: UIView, UIKeyInput {
	public let layoutEngine: PorticoTextLayoutEngine
	
	public init(frame: CGRect, layoutEngine: PorticoTextLayoutEngine) {
		self.layoutEngine = layoutEngine
		super.init(frame: frame)
		self.backgroundColor = .clear
		
		let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
		addGestureRecognizer(tap)
		
		let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
		addGestureRecognizer(pan)
	}
	
	public required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
	
	public override var canBecomeFirstResponder: Bool { return true }
	
	@objc private func handleTap(_ gesture: UITapGestureRecognizer) {
		becomeFirstResponder()
		var point = gesture.location(in: self)
		// UIView origin is top-left, but CoreText math expects bottom-left
		point.y = bounds.height - point.y
		let index = layoutEngine.stringIndex(for: point)
		layoutEngine.beginSelection(at: index)
		setNeedsDisplay()
	}
	
	@objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
		var point = gesture.location(in: self)
		point.y = bounds.height - point.y
		let index = layoutEngine.stringIndex(for: point)
		
		if gesture.state == .began {
			layoutEngine.beginSelection(at: index)
		} else if gesture.state == .changed {
			layoutEngine.updateSelection(to: index)
			setNeedsDisplay()
		}
	}
	
	public override func draw(_ rect: CGRect) {
		super.draw(rect)
		guard let context = UIGraphicsGetCurrentContext() else { return }
		layoutEngine.update(bounds: bounds.size)
		
		context.saveGState()
		context.translateBy(x: 0, y: bounds.height)
		context.scaleBy(x: 1.0, y: -1.0)
		layoutEngine.draw(in: context)
		context.restoreGState()
	}
	
	// MARK: - UIKeyInput
	public var hasText: Bool {
		return layoutEngine.attributedString.length > 0
	}
	
	public func insertText(_ text: String) {
		layoutEngine.insertText(text)
		setNeedsDisplay()
	}
	
	public func deleteBackward() {
		layoutEngine.deleteBackward()
		setNeedsDisplay()
	}
}
#endif
