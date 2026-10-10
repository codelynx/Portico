import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import Portico

// MARK: - Whole-document attributes (`setDocumentAttributes`)

private let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)

private func attributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
	[fontKey: CTFontCreateWithName("HiraginoSans-W3" as CFString, size, nil)]
}

private func documentEngine(_ text: String, size: CGFloat = 14) -> PorticoTextLayoutEngine {
	PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: text, attributes: attributes(size: size)),
		orientation: .vertical,
		bounds: CGSize(width: 600, height: 600))
}

/// The font size of every character, as a set — one entry when the whole document has one size.
private func fontSizes(_ engine: PorticoTextLayoutEngine) -> Set<CGFloat> {
	var sizes: Set<CGFloat> = []
	let string = engine.attributedString
	for index in 0..<string.length {
		guard let value = string.attribute(fontKey, at: index, effectiveRange: nil) else {
			sizes.insert(-1)
			continue
		}
		sizes.insert(CTFontGetSize(value as! CTFont))
	}
	return sizes
}

@Test @MainActor func documentAttributesReachEveryCharacter() {
	let engine = documentEngine("吾輩は猫である")
	engine.setDocumentAttributes(attributes(size: 28))
	#expect(fontSizes(engine) == [28])
	#expect(engine.attributedString.string == "吾輩は猫である")
}

@Test @MainActor func documentAttributesKeepRubyAndTateChuYoko() {
	let engine = documentEngine("漢字と12")
	engine.setRuby("かんじ", for: NSRange(location: 0, length: 2))
	engine.setTateChuYoko(.combine, for: NSRange(location: 3, length: 2))
	engine.setDocumentAttributes(attributes(size: 28))
	#expect(PorticoRuby.rubyGroup(at: 0, in: engine.attributedString)?.reading == "かんじ")
	#expect(engine.tateChuYokoOverride(at: 3) == .combine)
	#expect(fontSizes(engine) == [28])
}

@Test @MainActor func documentAttributesKeepTheUndoHistoryAndAddNoStep() {
	let engine = documentEngine("猫")
	engine.insertText("である")
	#expect(engine.undoManager.canUndo)
	engine.setDocumentAttributes(attributes(size: 28))
	#expect(engine.undoManager.canUndo, "the typing step is still there")
	engine.undoManager.undo()
	#expect(engine.attributedString.string == "猫", "the one undo step is the typing, not the look")
	#expect(!engine.undoManager.canUndo)
	#expect(fontSizes(engine) == [28], "text restored by undo wears the current look")
	engine.undoManager.redo()
	#expect(engine.attributedString.string == "猫である")
	#expect(fontSizes(engine) == [28])
}

@Test @MainActor func textTypedAfterwardsWearsTheNewLook() {
	let engine = documentEngine("猫")
	engine.setDocumentAttributes(attributes(size: 28))
	engine.insertText("だ")
	#expect(fontSizes(engine) == [28])
}

@Test @MainActor func anEmptyDocumentTakesTheLookWhenTypingStarts() {
	let engine = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: ""), orientation: .vertical,
		bounds: CGSize(width: 600, height: 600), typingAttributes: attributes(size: 14))
	engine.setDocumentAttributes(attributes(size: 28))
	engine.insertText("猫")
	#expect(fontSizes(engine) == [28])
}

@Test @MainActor func aCompositionInFlightSurvives() {
	let engine = documentEngine("猫")
	engine.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0), replacementRange: nil)
	let marked = engine.markedRange
	#expect(marked != nil)
	engine.setDocumentAttributes(attributes(size: 28))
	#expect(engine.markedRange == marked)
	#expect(engine.attributedString.string == "猫かん")
	engine.insertText("漢")
	#expect(engine.attributedString.string == "猫漢")
	#expect(fontSizes(engine) == [28])
	engine.undoManager.undo()
	#expect(engine.attributedString.string == "猫", "the composition is still one undo step")
	#expect(fontSizes(engine) == [28])
}

@Test @MainActor func aLargerFontMeasuresLarger() {
	let engine = documentEngine("吾輩は猫である")
	let before = engine.measuredSize()
	engine.setDocumentAttributes(attributes(size: 28))
	let after = engine.measuredSize()
	#expect(after.height > before.height * 1.8)
	#expect(after.width > before.width * 1.8)
}

@Test @MainActor func contentKeysAreIgnored() {
	let engine = documentEngine("漢字")
	var look = attributes(size: 28)
	look[PorticoTateChuYoko.overrideKey] = PorticoTateChuYoko.Override(.combine)
	engine.setDocumentAttributes(look)
	#expect(engine.tateChuYokoOverride(at: 0) == nil)
	#expect(fontSizes(engine) == [28])
}

@Test @MainActor func aDocumentResetForgetsTheLook() {
	let engine = documentEngine("猫")
	engine.setDocumentAttributes(attributes(size: 28))
	engine.update(attributedString: NSAttributedString(string: "犬", attributes: attributes(size: 10)))
	#expect(engine.documentAttributes == nil)
	#expect(fontSizes(engine) == [10])
}
