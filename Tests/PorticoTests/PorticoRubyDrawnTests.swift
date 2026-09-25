import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import Portico

// MARK: - Ruby drawn by Portico (ruby-typesetting arc, 2026-09-25)
//
// The base text is laid out as if the ruby were absent; each reading is drawn by Portico, centred
// on its word, and may overshoot the layout box or overlap its neighbours. A ruby word never breaks
// across lines unless it is longer than a whole line. MangaLoft docs/plans/ruby-typesetting-*.

private let font = CTFontCreateWithName("HiraMinProN-W3" as CFString, 28, nil)
private let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)

private func engine(_ source: String, vertical: Bool = true, bounds: CGSize? = nil) -> PorticoTextLayoutEngine {
	let m = NSMutableAttributedString(attributedString: PorticoRuby.parse(source))
	m.addAttribute(fontKey, value: font, range: NSRange(location: 0, length: m.length))
	let e = PorticoTextLayoutEngine(attributedString: m, orientation: vertical ? .vertical : .horizontal, bounds: .zero)
	e.update(bounds: bounds ?? e.measuredSize())
	return e
}

/// A long reading opening a column does NOT push its word: 東 starts where it would without ruby.
/// ⛔ Negative signature: 0.25 em (7 pt) lower — Core Text's own ruby moved the base.
@Test func aLongReadingDoesNotPushItsWordAtTheColumnStart() {
	let ruby = engine("あ\n東京《とうきょう》タ")
	let plain = engine("あ\n東京タ")
	#expect(abs(ruby.caretRect(for: 2).maxY - plain.caretRect(for: 2).maxY) < 0.5)
	#expect(abs(ruby.caretRect(for: 2).maxY - ruby.bounds.height) < 0.5, "東 at the column top")
}

/// Every caret position matches the same text without ruby — the base layout is untouched
/// (the index invariant: the layout copy maps 1:1).
@Test(arguments: [true, false])
func caretPositionsMatchTheTextWithoutRuby(vertical: Bool) {
	let ruby = engine("漢字《かんじ》の読《よ》み\n東京《とうきょう》タワー", vertical: vertical)
	let plain = engine("漢字の読み\n東京タワー", vertical: vertical)
	#expect(ruby.attributedString.length == plain.attributedString.length)
	for i in 0...plain.attributedString.length {
		let a = ruby.caretRect(for: i), b = plain.caretRect(for: i)
		#expect(abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5, "index \(i): \(a) vs \(b)")
	}
	#expect(ruby.measuredSize() == plain.measuredSize(), "the layout box ignores ruby")
}

/// Each reading is CENTRED on its word along the writing direction.
@Test(arguments: [true, false])
func theReadingIsCentredOnItsWord(vertical: Bool) {
	let e = engine("あ東京《とうきょう》あ", vertical: vertical)
	let placement = try! #require(e.rubyPlacements(stroke: nil).first)
	let width = CGFloat(CTLineGetTypographicBounds(placement.line, nil, nil, nil))
	let rubyMid = CGPoint(x: width / 2, y: 0).applying(placement.transform)
	let start = e.caretRect(for: 1), end = e.caretRect(for: 3)
	if vertical {
		#expect(abs(rubyMid.y - (start.maxY + end.maxY) / 2) < 0.5)
	} else {
		#expect(abs(rubyMid.x - (start.minX + end.minX) / 2) < 0.5)
	}
}

/// The reading's ink overshoots the layout box (a first-column reading sits beyond the box's
/// right edge in vertical text) and `inkBounds` includes it; the box does not.
@Test func inkBoundsIncludeOvershootingRuby() {
	let e = engine("東京《とうきょう》タワー")
	let ink = e.inkBounds()
	#expect(ink.maxX > e.bounds.width + 1, "ruby right of the first column, outside the box")
	#expect(ink.maxY > e.bounds.height + 1, "the long reading overshoots the column top")
}

/// A ruby word that would split at the line end moves WHOLE to the next line.
/// ⛔ Negative signature: 東 and 京 in different columns.
@Test func aRubyWordNeverSplitsAcrossColumns() {
	let limit = CGSize(width: 400, height: 3.5 * 28)
	let plain = engine("ああ東京ああ", bounds: limit)
	#expect(plain.caretRect(for: 2).minX != plain.caretRect(for: 3).minX, "control: the plain word DOES split here")
	let ruby = engine("ああ東京《とうきょう》ああ", bounds: limit)
	#expect(abs(ruby.caretRect(for: 2).minX - ruby.caretRect(for: 3).minX) < 0.5, "東京 stays in one column")
	#expect(abs(ruby.caretRect(for: 2).maxY - ruby.bounds.height) < 0.5, "and starts the next column")
}

/// ⛔ A ruby word LONGER than a whole column is allowed to break; kept whole, Core Text falls
/// back to one character per column for the ENTIRE text (S0 probe).
@Test func aRubyWordLongerThanAColumnMayBreak() {
	let e = engine("あ東京都庁舎《とうきょうとちょうしゃ》あ", bounds: CGSize(width: 400, height: 3.5 * 28))
	#expect(abs(e.caretRect(for: 0).minX - e.caretRect(for: 1).minX) < 0.5, "the first column holds more than one character")
}

/// Both drawing paths paint the reading: the live editor (`draw(in:)`) and the page renderer
/// (`drawText(in:)`) — otherwise ruby would vanish while editing.
@Test(arguments: [true, false])
func bothDrawingPathsPaintTheReading(editorPath: Bool) {
	let e = engine("\n東京《とうきょう》タワー")
	let placement = try! #require(e.rubyPlacements(stroke: nil).first)
	let rubyRect = CTLineGetBoundsWithOptions(placement.line, [.useGlyphPathBounds]).applying(placement.transform)
	let pad: CGFloat = 40
	let w = Int(e.bounds.width + pad * 2), h = Int(e.bounds.height + pad * 2)
	var data = [UInt8](repeating: 0, count: w * h * 4)
	data.withUnsafeMutableBytes { buffer in
		let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
		                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		ctx.translateBy(x: pad, y: pad)
		if editorPath { e.draw(in: ctx) } else { e.drawText(in: ctx) }
	}
	var inked = 0
	for py in 0..<h {
		let y = CGFloat(h - 1 - py) - pad // buffer row 0 is the TOP of the image (measured)
		guard y >= rubyRect.minY, y <= rubyRect.maxY else { continue }
		for px in 0..<w {
			let x = CGFloat(px) - pad
			guard x >= rubyRect.minX, x <= rubyRect.maxX else { continue }
			if data[(py * w + px) * 4 + 3] > 0 { inked += 1 }
		}
	}
	#expect(inked > 20, "reading painted beside its column (\(inked) px)")
}
