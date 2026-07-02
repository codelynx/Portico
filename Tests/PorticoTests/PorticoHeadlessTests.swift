import Testing
import Foundation
import CoreGraphics
@testable import Portico

// MARK: - Headless raster-service tests (PR-6: kickoff gap 13 verification)
//
// MangaLoft's TextRenderProvider retains an engine and re-draws it at whatever
// renderScale each render path needs (live view, thumbnail, 600-DPI export).
// These tests verify that usage: repeated drawText at different context scales is
// geometrically consistent, editing-state churn between draws doesn't leak into
// display output, and content replacement invalidates correctly — outline enabled
// throughout, so the stroke-frame cache (new state in 0.4.0) is churned too.

private let docSize = CGSize(width: 200, height: 200)
private let whiteC = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

private func makeEngine() -> PorticoTextLayoutEngine {
	let e = PorticoTextLayoutEngine(
		attributedString: PorticoRuby.parse("吾輩《わがはい》は猫\nである"),
		orientation: .vertical,
		bounds: docSize
	)
	e.outline = PorticoTextOutline(width: 2, color: whiteC)
	return e
}

/// Renders drawText at `scale` and returns the painted bounding box in POINT space
/// (pixel bbox divided back by scale) plus the raw pixels.
private func paintedBox(_ e: PorticoTextLayoutEngine, scale: CGFloat) -> (box: CGRect, data: [UInt8]) {
	let w = Int(docSize.width * scale), h = Int(docSize.height * scale)
	var data = [UInt8](repeating: 0, count: w * h * 4)
	data.withUnsafeMutableBytes { buffer in
		let ctx = CGContext(
			data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
			bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		)!
		ctx.scaleBy(x: scale, y: scale)
		e.drawText(in: ctx)
	}
	var box = CGRect.null
	for py in 0..<h {
		for px in 0..<w where data[(py * w + px) * 4 + 3] != 0 {
			box = box.union(CGRect(x: CGFloat(px), y: CGFloat(h - 1 - py), width: 1, height: 1))
		}
	}
	return (
		CGRect(x: box.minX / scale, y: box.minY / scale, width: box.width / scale, height: box.height / scale),
		data
	)
}

@Test func retainedEngineRendersConsistentlyAcrossScales() {
	let e = makeEngine()
	let base = paintedBox(e, scale: 1).box
	#expect(!base.isNull)
	for scale in [CGFloat(2), 8] {
		let scaled = paintedBox(e, scale: scale).box
		// Same geometry in point space, within a point of rasterization slop per edge.
		#expect(abs(scaled.minX - base.minX) < 1.5, "scale \(scale)")
		#expect(abs(scaled.maxY - base.maxY) < 1.5, "scale \(scale)")
		#expect(abs(scaled.width - base.width) < 3, "scale \(scale)")
		#expect(abs(scaled.height - base.height) < 3, "scale \(scale)")
	}
}

@Test func editingStateChurnDoesNotLeakIntoDisplayRender() {
	let e = makeEngine()
	let before = paintedBox(e, scale: 1).data
	// Churn every piece of editing state a provider-cached engine might carry.
	e.cursorIndex = 3
	e.setSelectedRange(NSRange(location: 0, length: 2))
	_ = paintedBox(e, scale: 2) // interleaved draw at another scale
	// Bounds churn too — the stale-layout posture re-measures and refreshes bounds
	// on cached engines; grow-then-restore must be output-neutral.
	e.update(bounds: CGSize(width: docSize.width + 40, height: docSize.height + 40))
	e.update(bounds: docSize)
	e.setSelectedRange(NSRange(location: 0, length: 0))
	e.cursorIndex = 0
	let after = paintedBox(e, scale: 1).data
	#expect(before == after)
}

@Test func contentReplacementInvalidatesRender() {
	let e = makeEngine()
	let before = paintedBox(e, scale: 1).data
	e.update(attributedString: PorticoRuby.parse("別《べつ》の内容"))
	let after = paintedBox(e, scale: 1).data
	#expect(before != after)
}
