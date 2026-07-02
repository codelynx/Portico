import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import Portico

#if canImport(UIKit)
private let bigFont = UIFont.systemFont(ofSize: 40)
#elseif canImport(AppKit)
private let bigFont = NSFont.systemFont(ofSize: 40)
#endif

// MARK: - Outline tests (PR-4: PorticoTextOutline / 縁取り)
//
// Includes the plan's R1 gate: ruby readings MUST be outlined too (furigana over
// artwork needs the halo as much as the base text). If Core Text doesn't propagate
// the base run's stroke attributes to CTRubyAnnotation glyphs, rubyIsOutlined
// fails and the plan's fallback (rebuild annotations with stroke attributes in the
// stroke pass) must ship.

private let outlineBounds = CGSize(width: 300, height: 300)
private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

private func outlineEngine(
	_ attributed: NSAttributedString,
	orientation: PorticoLayoutOrientation = .horizontal,
	outline: PorticoTextOutline? = nil
) -> PorticoTextLayoutEngine {
	let e = PorticoTextLayoutEngine(
		attributedString: attributed,
		orientation: orientation,
		bounds: outlineBounds
	)
	e.outline = outline
	return e
}

private func outlineEngine(
	_ s: String,
	orientation: PorticoLayoutOrientation = .horizontal,
	outline: PorticoTextOutline? = nil
) -> PorticoTextLayoutEngine {
	outlineEngine(NSAttributedString(string: s), orientation: orientation, outline: outline)
}

/// Renders drawText into an RGBA bitmap.
private func render(_ e: PorticoTextLayoutEngine, size: CGSize = outlineBounds) -> [UInt8] {
	let w = Int(size.width), h = Int(size.height)
	var data = [UInt8](repeating: 0, count: w * h * 4)
	data.withUnsafeMutableBytes { buffer in
		let ctx = CGContext(
			data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
			bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		)!
		e.drawText(in: ctx)
	}
	return data
}

/// Count of pixels that read as the (premultiplied) white outline vs dark fill.
private func whiteAndDarkCounts(_ data: [UInt8]) -> (white: Int, dark: Int) {
	var white = 0, dark = 0
	for i in stride(from: 0, to: data.count, by: 4) {
		let r = data[i], a = data[i + 3]
		guard a > 128 else { continue }
		if r > 200 { white += 1 } else if r < 60 { dark += 1 }
	}
	return (white, dark)
}

// MARK: baseline behavior unchanged

@Test func outlineSetThenClearedRestoresBaseline() {
	// The meaningful nil test: exercises the didSet stroke-cache invalidation in
	// BOTH directions (the stale-cache bug class), not nil-to-nil tautology.
	let e = outlineEngine("縁取りなし")
	let baseline = render(e)
	e.outline = .init(width: 2, color: white)
	let outlined = render(e)
	e.outline = nil
	let restored = render(e)
	#expect(outlined != baseline)
	#expect(restored == baseline)
}

@Test func foreignRubyKeyValueDoesNotTrapWithOutline() {
	// Portico treats non-CTRubyAnnotation values under the ruby key as non-ruby
	// (serializer test precedent); the outline stroke pass must not force-cast-trap
	// on the same input.
	let s = NSMutableAttributedString(string: "外部値テスト")
	s.addAttribute(PorticoRuby.rubyKey, value: "not an annotation", range: NSRange(location: 0, length: 3))
	let e = outlineEngine(s, outline: .init(width: 2, color: white))
	let data = render(e) // must not crash
	#expect(data.contains { $0 != 0 }) // and still renders the text + rim
}

@Test func invalidOutlineWidthsBehaveAsOff() {
	let text = "無効な縁"
	let baseline = render(outlineEngine(text))
	for width in [CGFloat(0), -3, .nan, .infinity] {
		#expect(render(outlineEngine(text, outline: .init(width: width, color: white))) == baseline)
	}
}

// MARK: the outline paints, behind the fill

@Test func outlineAddsRimBehindFill() {
	// 40pt glyphs so interiors dominate over AA edges (at default 12pt nearly every
	// glyph pixel is an edge pixel and the interior count is too noisy to assert on).
	let attributed = NSAttributedString(string: "縁取り文字", attributes: [.font: bigFont])
	let plain = whiteAndDarkCounts(render(outlineEngine(attributed)))
	let outlined = whiteAndDarkCounts(render(outlineEngine(attributed, outline: .init(width: 2, color: white))))

	#expect(plain.white == 0) // no white anywhere without the outline
	#expect(outlined.white > 100) // the rim exists
	#expect(outlined.dark > plain.dark / 2) // fill still on top (glyph interiors stay dark)
}

@Test func editingAndDisplayRendersAgreeWithOutline() {
	let e = outlineEngine("縁", outline: .init(width: 2, color: white))
	e.drawsSelectionHighlight = false
	let w = Int(outlineBounds.width), h = Int(outlineBounds.height)
	func run(_ draw: (CGContext) -> Void) -> [UInt8] {
		var data = [UInt8](repeating: 0, count: w * h * 4)
		data.withUnsafeMutableBytes { buffer in
			let ctx = CGContext(
				data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
				bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)!
			draw(ctx)
		}
		return data
	}
	#expect(run { e.draw(in: $0) } == run { e.drawText(in: $0) })
}

// MARK: stroke pass must not change layout (the load-bearing two-frame assumption)

@Test func strokeFrameLineOriginsMatchFillFrame() {
	let attributed = PorticoRuby.parse("吾輩《わがはい》は猫である\n名前はまだ無い")
	for orientation in [PorticoLayoutOrientation.horizontal, .vertical] {
		let e = outlineEngine(attributed, orientation: orientation, outline: .init(width: 3, color: white))
		let fill = e.lineOrigins()
		let stroke = e.strokeFrameLineOrigins()
		#expect(!fill.isEmpty)
		#expect(fill == stroke)
	}
}

// MARK: R1 gate — ruby readings are outlined too

@Test func rubyIsOutlined() {
	// Black fill + white outline: the ruby overhang band must contain white rim
	// pixels. If this fails, Core Text is not propagating stroke attributes to
	// CTRubyAnnotation glyphs and the stroke pass must rebuild annotations with
	// stroke attributes (the plan's R1 fallback — shipped).
	//
	// Band threshold: the OUTLINED no-ruby baseline's ink top (base rim included) +
	// slop, so base-glyph rim pixels can't masquerade as ruby rim. 40pt font makes
	// the ruby band fat enough for the count to have real margin.
	let outlineSpec = PorticoTextOutline(width: 2, color: white)
	let baseAttributed = NSAttributedString(string: "世界を見る", attributes: [.font: bigFont])
	let outlinedBaseInk = outlineEngine(baseAttributed, outline: outlineSpec).inkBounds()

	let rubyAttributed = NSMutableAttributedString(attributedString: PorticoRuby.parse("世界《せかい》を見る"))
	rubyAttributed.addAttribute(.font, value: bigFont, range: NSRange(location: 0, length: rubyAttributed.length))
	let e = outlineEngine(rubyAttributed, outline: outlineSpec)
	let data = render(e)

	let w = Int(outlineBounds.width), h = Int(outlineBounds.height)
	var whiteInRubyBand = 0
	for py in 0..<h {
		let engineY = CGFloat(h - 1 - py)
		guard engineY > outlinedBaseInk.maxY + 2 else { continue } // clear of the base rim
		for px in 0..<w {
			let i = (py * w + px) * 4
			if data[i + 3] > 128 && data[i] > 200 { whiteInRubyBand += 1 }
		}
	}
	#expect(whiteInRubyBand > 20, "ruby reading is not outlined — R1 fallback needed")
}

// MARK: inkBounds outset + containment

@Test func inkBoundsGrowsByOutlineWidth() {
	let text = "縁取り"
	let width: CGFloat = 3
	let plain = outlineEngine(text).inkBounds()
	let outlined = outlineEngine(text, outline: .init(width: width, color: white)).inkBounds()
	#expect(outlined == plain.insetBy(dx: -width, dy: -width))
}

@Test func inkBoundsContainOutlinedPixels() {
	// The padded containment proof, outline enabled: every painted pixel — rim,
	// fill, and outlined ruby, both orientations — falls inside inkBounds().
	let pad: CGFloat = 40
	for orientation in [PorticoLayoutOrientation.horizontal, .vertical] {
		let e = outlineEngine(
			PorticoRuby.parse("吾輩《わがはい》は猫"),
			orientation: orientation,
			outline: .init(width: 3, color: white)
		)
		let ink = e.inkBounds()
		let w = Int(outlineBounds.width + 2 * pad), h = Int(outlineBounds.height + 2 * pad)
		var data = [UInt8](repeating: 0, count: w * h * 4)
		data.withUnsafeMutableBytes { buffer in
			let ctx = CGContext(
				data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
				bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)!
			ctx.translateBy(x: pad, y: pad)
			e.drawText(in: ctx)
		}
		var painted = CGRect.null
		for py in 0..<h {
			for px in 0..<w where data[(py * w + px) * 4 + 3] != 0 {
				painted = painted.union(CGRect(
					x: CGFloat(px) - pad, y: CGFloat(h - 1 - py) - pad, width: 1, height: 1
				))
			}
		}
		#expect(!painted.isNull)
		#expect(ink.insetBy(dx: -1.5, dy: -1.5).contains(painted), "\(orientation): ink \(ink) should contain painted \(painted)")
	}
}
