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

public class PorticoTextLayoutEngine {
	public var attributedString: NSAttributedString
	public var orientation: PorticoLayoutOrientation
	public private(set) var bounds: CGSize
	public var cursorIndex: Int = 0
	public var selectionRange: NSRange?
	public var markedRange: NSRange?
	private var selectionAnchorIndex: Int?
	public var textDidChange: ((NSAttributedString) -> Void)?
	
	private var frameSetter: CTFramesetter?
	private var textFrame: CTFrame?
	
	public init(attributedString: NSAttributedString, orientation: PorticoLayoutOrientation = .horizontal, bounds: CGSize = .zero) {
		self.attributedString = attributedString
		self.orientation = orientation
		self.bounds = bounds
		self.cursorIndex = attributedString.length
		updateLayout()
	}
	
	public func update(attributedString: NSAttributedString) {
		self.attributedString = attributedString
		updateLayout()
	}
	
	public func update(bounds: CGSize) {
		if self.bounds != bounds {
			self.bounds = bounds
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
		cursorIndex = index
		selectionAnchorIndex = index
		selectionRange = nil
	}
	
	public func updateSelection(to index: Int) {
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
	
	public func setMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange?) {
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		let attrs = cursorIndex > 0 ? mutableString.attributes(at: cursorIndex - 1, effectiveRange: nil) : [:]
		
		var markedAttrs = attrs
		markedAttrs[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
		
		let insertedString = NSAttributedString(string: text, attributes: markedAttrs)
		
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
		
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		mutableString.removeAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String), range: mr)
		
		self.attributedString = mutableString
		self.markedRange = nil
		textDidChange?(self.attributedString)
		updateLayout()
	}
	
	public enum MoveDirection {
		case left, right, up, down
	}
	
	private func targetIndex(for direction: MoveDirection) -> Int {
		switch direction {
		case .left:
			if orientation == .horizontal {
				return max(0, cursorIndex - 1)
			} else {
				let rect = caretRect(for: cursorIndex)
				let point = CGPoint(x: rect.midX - rect.width, y: rect.midY)
				return stringIndex(for: point)
			}
		case .right:
			if orientation == .horizontal {
				return min(attributedString.length, cursorIndex + 1)
			} else {
				let rect = caretRect(for: cursorIndex)
				let point = CGPoint(x: rect.midX + rect.width, y: rect.midY)
				return stringIndex(for: point)
			}
		case .up:
			if orientation == .horizontal {
				let rect = caretRect(for: cursorIndex)
				let point = CGPoint(x: rect.midX, y: rect.midY + rect.height)
				return stringIndex(for: point)
			} else {
				return max(0, cursorIndex - 1)
			}
		case .down:
			if orientation == .horizontal {
				let rect = caretRect(for: cursorIndex)
				let point = CGPoint(x: rect.midX, y: rect.midY - rect.height)
				return stringIndex(for: point)
			} else {
				return min(attributedString.length, cursorIndex + 1)
			}
		}
	}
	
	public func moveCursor(direction: MoveDirection, modifySelection: Bool = false) {
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
		
		setNeedsDisplay()
	}
	
	private func setNeedsDisplay() {
		// Just trigger a re-draw notification (handled by whoever owns textDidChange if needed, or view directly)
		// Wait, view triggers setNeedsDisplay itself, so we don't strictly need to call textDidChange unless text changed.
	}
	
	public func insertText(_ text: String) {
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		let attrs = cursorIndex > 0 ? mutableString.attributes(at: cursorIndex - 1, effectiveRange: nil) : [:]
		
		// Remove underline if we are pulling attributes from previously marked text
		var cleanAttrs = attrs
		cleanAttrs.removeValue(forKey: NSAttributedString.Key(kCTUnderlineStyleAttributeName as String))
		
		let insertedString = NSAttributedString(string: text, attributes: cleanAttrs)
		
		let targetRange: NSRange
		if let mr = markedRange {
			targetRange = mr
		} else if let sr = selectionRange {
			targetRange = sr
		} else {
			targetRange = NSRange(location: cursorIndex, length: 0)
		}
		
		mutableString.replaceCharacters(in: targetRange, with: insertedString)
		self.cursorIndex = targetRange.location + text.utf16.count
		self.selectionRange = nil
		self.markedRange = nil
		
		self.attributedString = mutableString
		textDidChange?(self.attributedString)
		updateLayout()
	}
	
	public func deleteBackward() {
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		
		if let range = selectionRange {
			mutableString.deleteCharacters(in: range)
			self.cursorIndex = range.location
			self.selectionRange = nil
		} else {
			guard cursorIndex > 0 else { return }
			let range = NSRange(location: cursorIndex - 1, length: 1)
			mutableString.deleteCharacters(in: range)
			self.cursorIndex -= 1
		}
		
		self.attributedString = mutableString
		textDidChange?(self.attributedString)
		updateLayout()
	}
	
	public func stringIndex(for point: CGPoint) -> Int {
		guard let textFrame = textFrame else { return 0 }
		
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return 0 }
		
		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)
		
		var closestLineIndex = 0
		var minDistance: CGFloat = .greatestFiniteMagnitude
		
		for i in 0..<lines.count {
			let origin = origins[i]
			let dist: CGFloat
			if orientation == .vertical {
				dist = abs(point.x - origin.x)
			} else {
				dist = abs(point.y - origin.y)
			}
			if dist < minDistance {
				minDistance = dist
				closestLineIndex = i
			}
		}
		
		let closestLine = lines[closestLineIndex]
		let origin = origins[closestLineIndex]
		
		let relativePoint: CGPoint
		if orientation == .vertical {
			// For vertical text, the CTLine's internal advance axis (X) corresponds to the visual Y axis (going down).
			relativePoint = CGPoint(x: origin.y - point.y, y: 0)
		} else {
			// For horizontal text, internal X corresponds to visual X (going right).
			relativePoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
		}
		
		return CTLineGetStringIndexForPosition(closestLine, relativePoint)
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
					let x = origin.x - descent
					// CoreText vertical offsets move down visually, so we subtract from Y
					let y = origin.y - offset
					return CGRect(x: x, y: y, width: ascent + descent, height: 2)
				} else {
					let x = origin.x + offset
					let y = origin.y - descent
					return CGRect(x: x, y: y, width: 2, height: ascent + descent)
				}
			}
		}
		return .zero
	}
	
	/// Natural height of a line that carries one row of ruby, measured from a real
	/// CTLine using the string's own base attributes. Self-calibrating: it reflects
	/// the font Core Text actually uses (including CJK fallbacks) and the real ruby
	/// ascent, so no hand-tuned reserve ratio is needed.
	private func rubyLinePitch() -> CGFloat {
		var attrs: [NSAttributedString.Key: Any] = [:]
		if attributedString.length > 0 {
			attrs = attributedString.attributes(at: 0, effectiveRange: nil)
			attrs.removeValue(forKey: NSAttributedString.Key(kCTRubyAnnotationAttributeName as String))
		}
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

	private func updateLayout() {
		guard bounds.width > 0 && bounds.height > 0 else {
			self.frameSetter = nil
			self.textFrame = nil
			return
		}
		
		// Prepare the string for layout. We always apply a fixed line pitch (and,
		// for vertical text, vertical glyph forms) so we work on a copy.
		let mutableString = NSMutableAttributedString(attributedString: attributedString)
		let fullRange = NSRange(location: 0, length: mutableString.length)

		// Reserve a uniform line-to-line pitch large enough to hold ruby on every
		// line, so lines stay evenly spaced whether or not they carry ruby (no
		// デコボコ). Merge it into any caller-supplied paragraph style rather than
		// overwriting, so alignment / indents / spacing survive.
		let pitch = rubyLinePitch()
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
		}
		let stringToLayout: NSAttributedString = mutableString
		
		let setter = CTFramesetterCreateWithAttributedString(stringToLayout as CFAttributedString)
		self.frameSetter = setter
		
		let path = CGMutablePath()
		path.addRect(CGRect(origin: .zero, size: bounds))
		
		let frameAttributes: [CFString: Any] = [
			kCTFrameProgressionAttributeName: orientation == .vertical ? 
				CTFrameProgression.rightToLeft.rawValue : 
				CTFrameProgression.topToBottom.rawValue
		]
		
		self.textFrame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, frameAttributes as CFDictionary)
	}
	
	private func drawSelection(in context: CGContext) {
		guard let textFrame = textFrame, let selectionRange = selectionRange else { return }
		let lines = CTFrameGetLines(textFrame) as! [CTLine]
		guard !lines.isEmpty else { return }
		
		var origins = [CGPoint](repeating: .zero, count: lines.count)
		CTFrameGetLineOrigins(textFrame, CFRangeMake(0, 0), &origins)
		
		context.setFillColor(CGColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 0.3))
		
		for i in 0..<lines.count {
			let line = lines[i]
			let lineRange = CTLineGetStringRange(line)
			let nsLineRange = NSRange(location: lineRange.location, length: lineRange.length)
			let intersection = NSIntersectionRange(nsLineRange, selectionRange)
			
			if intersection.length > 0 {
				let startOffset = CTLineGetOffsetForStringIndex(line, intersection.location, nil)
				let endOffset = CTLineGetOffsetForStringIndex(line, intersection.location + intersection.length, nil)
				
				var ascent: CGFloat = 0
				var descent: CGFloat = 0
				var leading: CGFloat = 0
				CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
				
				let origin = origins[i]
				let rectWidthOrHeight = endOffset > startOffset ? endOffset - startOffset : startOffset - endOffset
				
				let rect: CGRect
				if orientation == .vertical {
					let yBottom = origin.y - max(startOffset, endOffset)
					rect = CGRect(x: origin.x - descent, y: yBottom, width: ascent + descent, height: rectWidthOrHeight)
				} else {
					let xLeft = origin.x + min(startOffset, endOffset)
					rect = CGRect(x: xLeft, y: origin.y - descent, width: rectWidthOrHeight, height: ascent + descent)
				}
				context.fill(rect)
			}
		}
	}
	
	public func draw(in context: CGContext) {
		guard let textFrame = textFrame else { return }
		
		context.saveGState()
		
		// Draw selection highlight first so text is drawn over it
		drawSelection(in: context)
		
		// CoreText natively handles vertical layout geometry when progression is rightToLeft 
		// and kCTVerticalFormsAttributeName is applied. No context rotation needed on macOS!
		
		CTFrameDraw(textFrame, context)
		
		// Draw the caret if there is no selection
		if selectionRange == nil && markedRange == nil {
			let rect = caretRect(for: cursorIndex)
			context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
			context.fill(rect)
		}
		
		context.restoreGState()
	}
}
