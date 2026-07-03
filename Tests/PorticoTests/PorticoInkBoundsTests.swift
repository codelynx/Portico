import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import Portico

// MARK: - Ink-bounds tests (PR-5: inkBounds() core — no outline outset yet, that's PR-4)
//
// These tests double as the plan's R2 verification: whether ruby annotation extents
// are included in CTLineGetBoundsWithOptions(.useGlyphPathBounds). The ruby-growth
// assertions fail loudly if Core Text excludes ruby, which triggers the plan's
// corrected fallback (real reading extents, NOT base-glyph rects).

private let boundsSize = CGSize(width: 400, height: 400)

#if canImport(UIKit)
private let bigInkFont = UIFont.systemFont(ofSize: 36)
#elseif canImport(AppKit)
private let bigInkFont = NSFont.systemFont(ofSize: 36)
#endif

private func laidOutEngine(
	_ attributed: NSAttributedString,
	orientation: PorticoLayoutOrientation
) -> PorticoTextLayoutEngine {
	PorticoTextLayoutEngine(attributedString: attributed, orientation: orientation, bounds: boundsSize)
}

private func laidOutEngine(
	_ s: String,
	orientation: PorticoLayoutOrientation
) -> PorticoTextLayoutEngine {
	laidOutEngine(NSAttributedString(string: s), orientation: orientation)
}

// MARK: basics

@Test func inkBoundsNullWithoutLayout() {
	let e = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: "text"),
		orientation: .horizontal,
		bounds: .zero
	)
	#expect(e.inkBounds().isNull)
}

@Test func inkBoundsNonEmptyAndSane() {
	for orientation in [PorticoLayoutOrientation.horizontal, .vertical] {
		let ink = laidOutEngine("こんにちは", orientation: orientation).inkBounds()
		#expect(!ink.isNull && !ink.isEmpty)
		// Sane: ink sits within the layout rect's general vicinity (glyph path bounds
		// of plain text without ruby stay inside the frame).
		#expect(ink.minX > -5 && ink.minY > -5)
		#expect(ink.maxX < boundsSize.width + 5 && ink.maxY < boundsSize.height + 5)
	}
}

@Test func inkBoundsSkipsEmptyLines() {
	// "あ\n\nい" has an empty middle line whose glyph bounds are null/empty; the
	// union must not degrade into a giant or zero-anchored rect.
	let e = laidOutEngine("あ\n\nい", orientation: .horizontal)
	let ink = e.inkBounds()
	#expect(!ink.isNull && !ink.isEmpty)
	#expect(ink.width < 60) // two single-kana lines: narrow union, not bounds-wide
	// Spans three line pitches vertically (first and third lines carry the ink).
	#expect(ink.height > 40)
}

// MARK: ruby overhang (R2 verification — growth on the ascent side)

@Test func inkBoundsRubyGrowsTopInHorizontal() {
	let plain = laidOutEngine("世界を見る", orientation: .horizontal).inkBounds()
	let ruby = laidOutEngine(PorticoRuby.parse("世界《せかい》を見る"), orientation: .horizontal).inkBounds()
	// Ruby renders above the base in horizontal (ascent side): the ink top must rise.
	// Engine coords are bottom-left, first line sits at the frame top, so "higher" = larger maxY.
	#expect(ruby.maxY > plain.maxY + 1)
}

@Test func inkBoundsRubyGrowsRightInVertical() {
	let plain = laidOutEngine("世界を見る", orientation: .vertical).inkBounds()
	let ruby = laidOutEngine(PorticoRuby.parse("世界《せかい》を見る"), orientation: .vertical).inkBounds()
	// Ruby renders right of the column in vertical (ascent side): ink right edge grows.
	#expect(ruby.maxX > plain.maxX + 1)
}

@Test func inkBoundsLongReadingGrowsInlineExtent() {
	// A reading much wider than its base overhangs along the ADVANCE axis too.
	// Both fixtures lay out the same base glyphs (parse strips the ｜ marker, so the
	// plain side must not carry one).
	for orientation in [PorticoLayoutOrientation.horizontal, .vertical] {
		let plain = laidOutEngine("社会を見る", orientation: orientation).inkBounds()
		let ruby = laidOutEngine(PorticoRuby.parse("｜社会《ソサイエティー》を見る"), orientation: orientation).inkBounds()
		// Not an exact-width claim — the long reading's ink extends at least as far
		// along the advance axis as the base-only text, and grows on the ascent side.
		if orientation == .vertical {
			#expect(ruby.height > plain.height - 1)
			#expect(ruby.maxX > plain.maxX + 1)
		} else {
			#expect(ruby.width > plain.width - 1)
			#expect(ruby.maxY > plain.maxY + 1)
		}
	}
}

@Test func inkBoundsContainLineFinalLongReadingRuby() {
	// Regression (found by the MangaLoft integration containment test): a
	// reading wider than its base, sitting at the LINE END, overhangs past the
	// line's last advance — line glyph-path bounds exclude that overhang.
	// Padded-bitmap containment in both orientations, big font for margin.
	let pad: CGFloat = 60
	for orientation in [PorticoLayoutOrientation.horizontal, .vertical] {
		let attributed = NSMutableAttributedString(
			attributedString: PorticoRuby.parse("\u{3000}\u{3000}世《せかい》"))
		attributed.addAttribute(
			.font, value: bigInkFont, range: NSRange(location: 0, length: attributed.length))
		let e = PorticoTextLayoutEngine(
			attributedString: attributed, orientation: orientation, bounds: boundsSize)
		let ink = e.inkBounds()

		let w = Int(boundsSize.width + 2 * pad), h = Int(boundsSize.height + 2 * pad)
		var data = [UInt8](repeating: 0, count: w * h * 4)
		data.withUnsafeMutableBytes { buffer in
			let ctx = CGContext(
				data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
				bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
			ctx.translateBy(x: pad, y: pad)
			e.drawText(in: ctx)
		}
		var painted = CGRect.null
		for py in 0..<h {
			for px in 0..<w where data[(py * w + px) * 4 + 3] != 0 {
				painted = painted.union(CGRect(
					x: CGFloat(px) - pad, y: CGFloat(h - 1 - py) - pad, width: 1, height: 1))
			}
		}
		#expect(!painted.isNull)
		#expect(ink.insetBy(dx: -1.5, dy: -1.5).contains(painted),
			"\(orientation): ink \(ink) must contain painted \(painted)")
	}
}

@Test func inkBoundsAllNewlinesIsNull() {
	// Laid out, but nothing painted: whitespace/newline-only content has no ink.
	#expect(laidOutEngine("\n\n", orientation: .horizontal).inkBounds().isNull)
}

@Test func lineLocalMappingHandlesNegativeExtrema() {
	// Synthetic check locking the affine (hanging punctuation / overhang can give
	// negative line-local minX or minY; the mapper must use actual extrema).
	let local = CGRect(x: -3, y: -2, width: 10, height: 6) // minX -3, maxX 7, minY -2, maxY 4
	let origin = CGPoint(x: 100, y: 200)

	let h = laidOutEngine("a", orientation: .horizontal).lineLocalToEngineRect(local, lineOrigin: origin)
	#expect(h == CGRect(x: 97, y: 198, width: 10, height: 6))

	let v = laidOutEngine("a", orientation: .vertical).lineLocalToEngineRect(local, lineOrigin: origin)
	// Advance x → engine y: [200 − 7, 200 − (−3)] = [193, 203]; cross y → engine x: [98, 104].
	#expect(v == CGRect(x: 98, y: 193, width: 6, height: 10))
}

// MARK: containment — ink bounds must cover what drawText paints

@Test func inkBoundsContainPaintedPixels() {
	// Render via drawText into a PADDED bitmap (the context is translated so ink
	// that overhangs the layout rect — first-line ruby above it in horizontal,
	// first-column ruby right of it in vertical — still lands inside the scanned
	// area instead of being silently cropped) and assert every non-transparent
	// pixel falls inside inkBounds.
	let pad: CGFloat = 40
	for orientation in [PorticoLayoutOrientation.horizontal, .vertical] {
		let e = laidOutEngine(PorticoRuby.parse("吾輩《わがはい》は猫"), orientation: orientation)
		let ink = e.inkBounds()
		let width = Int(boundsSize.width + 2 * pad), height = Int(boundsSize.height + 2 * pad)
		var data = [UInt8](repeating: 0, count: width * height * 4)
		data.withUnsafeMutableBytes { buffer in
			let context = CGContext(
				data: buffer.baseAddress, width: width, height: height,
				bitsPerComponent: 8, bytesPerRow: width * 4,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)!
			context.translateBy(x: pad, y: pad)
			e.drawText(in: context)
		}
		// CGContext row 0 is the TOP row in memory; engine/CT coords are bottom-left.
		// Pixel (px, py-from-top) → engine point (px − pad, height − 1 − py − pad).
		var painted = CGRect.null
		for py in 0..<height {
			for px in 0..<width where data[(py * width + px) * 4 + 3] != 0 {
				let point = CGRect(
					x: CGFloat(px) - pad,
					y: CGFloat(height - 1 - py) - pad,
					width: 1,
					height: 1
				)
				painted = painted.union(point)
			}
		}
		#expect(!painted.isNull)
		// Allow 1px of AA slop on each side.
		#expect(ink.insetBy(dx: -1.5, dy: -1.5).contains(painted), "\(orientation): ink \(ink) should contain painted \(painted)")
	}
}
