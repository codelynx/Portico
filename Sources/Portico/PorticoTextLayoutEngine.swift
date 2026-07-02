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
	/// Whether the engine draws its own selection highlight. macOS keeps this on (it owns
	/// rendering); iOS turns it off so `UITextInteraction` renders the native selection
	/// tint + handles, avoiding a doubled fill.
	public var drawsSelectionHighlight: Bool = true

	/// Whether the engine draws the caret itself: when it owns rendering (macOS) OR the
	/// text is vertical — UIKit's `UITextInteraction` can't render a vertical-text caret
	/// (it collapses our wide-short caret rect to a stub), so the engine draws it even when
	/// iOS otherwise owns selection. Computed from the live `orientation` so a runtime
	/// orientation change can't leave it stale.
	public var drawsCaret: Bool { drawsSelectionHighlight || orientation == .vertical }
	private var selectionAnchorIndex: Int?
	private let rubyAttributeKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
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

	/// Sets the selection from an external source (e.g. UIKit's `selectedTextRange`),
	/// seeding the internal anchor so a later Shift+Arrow (`moveCursor`) extends from
	/// the right end instead of a nil/stale anchor. A zero-length range collapses to a
	/// caret; otherwise the anchor is the range start and the cursor its end.
	public func setSelectedRange(_ range: NSRange) {
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
	
	public func setMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange?) {
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

		let attrs = cursorIndex > 0 ? mutableString.attributes(at: cursorIndex - 1, effectiveRange: nil) : [:]
		var markedAttrs = attrs
		markedAttrs[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
		// Same ruby attribute-edge rule as insertText: composing text joins a ruby group only
		// when strictly inside one; at a boundary it must not inherit the base's ruby (§6).
		if !insertionExtendsRubyGroup(at: targetRange.location, replacing: targetRange.length, in: mutableString) {
			markedAttrs.removeValue(forKey: rubyAttributeKey)
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
		guard string.attribute(rubyAttributeKey, at: beforeIndex, effectiveRange: &beforeRange) != nil else { return false }
		return NSLocationInRange(afterIndex, beforeRange)
	}

	public func insertText(_ text: String) {
		let mutableString = NSMutableAttributedString(attributedString: attributedString)

		let targetRange: NSRange
		if let mr = markedRange {
			targetRange = mr
		} else if let sr = selectionRange {
			targetRange = sr
		} else {
			targetRange = NSRange(location: cursorIndex, length: 0)
		}

		let attrs = cursorIndex > 0 ? mutableString.attributes(at: cursorIndex - 1, effectiveRange: nil) : [:]
		var cleanAttrs = attrs
		// Don't carry the IME underline into committed text.
		cleanAttrs.removeValue(forKey: NSAttributedString.Key(kCTUnderlineStyleAttributeName as String))
		// Ruby attribute-edge rule: inserted text joins a ruby group only when it lands
		// strictly inside one; at a group boundary it is plain text — fixes typing after a
		// base extending its ruby. See Docs/RubyEditing-Design.md §6.
		if !insertionExtendsRubyGroup(at: targetRange.location, replacing: targetRange.length, in: mutableString) {
			cleanAttrs.removeValue(forKey: rubyAttributeKey)
		}

		let insertedString = NSAttributedString(string: text, attributes: cleanAttrs)
		mutableString.replaceCharacters(in: targetRange, with: insertedString)
		var newCursor = targetRange.location + text.utf16.count
		// Inline notation: a just-committed `》` closing `…《reading》` converts to a ruby group
		// (§7a). Only here (committed text) — never in setMarkedText (IME composition).
		newCursor = convertInlineRuby(in: mutableString, cursor: newCursor)
		self.cursorIndex = newCursor
		self.selectionRange = nil
		self.markedRange = nil

		self.attributedString = mutableString
		textDidChange?(self.attributedString)
		updateLayout()
	}

	/// Converts a just-closed inline ruby run `[｜]base《reading》` into a ruby group (§7a),
	/// preserving the base text's existing attributes. Mutates `string`; returns the updated
	/// cursor (end of the base) or `cursor` unchanged when there's nothing to convert.
	private func convertInlineRuby(in string: NSMutableAttributedString, cursor: Int) -> Int {
		guard cursor > 0,
			  let match = PorticoRuby.inlineRubyMatch(
				in: string.string as NSString,
				closingAt: cursor - 1,
				// Auto-base must not swallow a character already in a ruby group.
				isRuby: { string.attribute(self.rubyAttributeKey, at: $0, effectiveRange: nil) != nil })
		else { return cursor }
		// Keep the base with its attributes, drop the marks + reading, then attach the ruby.
		let base = NSMutableAttributedString(attributedString: string.attributedSubstring(from: match.baseRange))
		PorticoRuby.setRuby(match.reading, for: NSRange(location: 0, length: base.length), in: base)
		string.replaceCharacters(in: match.sourceRange, with: base)
		return match.sourceRange.location + base.length
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
		guard let selectionRange = selectionRange else { return }
		context.setFillColor(CGColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 0.3))
		for rect in selectionRects(for: selectionRange) {
			context.fill(rect)
		}
	}
	
	public func draw(in context: CGContext) {
		guard let textFrame = textFrame else { return }
		
		context.saveGState()

		// Draw selection highlight first so text is drawn over it
		if drawsSelectionHighlight {
			drawSelection(in: context)
		}

		// CoreText natively handles vertical layout geometry when progression is rightToLeft
		// and kCTVerticalFormsAttributeName is applied. No context rotation needed on macOS!

		CTFrameDraw(textFrame, context)

		// Draw the caret when the engine owns it (see `drawsCaret`).
		if drawsCaret && selectionRange == nil && markedRange == nil {
			let rect = caretRect(for: cursorIndex)
			context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
			context.fill(rect)
		}

		context.restoreGState()
	}
}
