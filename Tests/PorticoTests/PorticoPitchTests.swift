import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import Portico

// MARK: - Line-pitch tests (PR-3: linePitchMultiplier)

private let pitchBounds = CGSize(width: 600, height: 600)

private func pitchEngine(
	_ s: String,
	orientation: PorticoLayoutOrientation = .horizontal,
	multiplier: CGFloat? = nil
) -> PorticoTextLayoutEngine {
	let e = PorticoTextLayoutEngine(
		attributedString: NSAttributedString(string: s),
		orientation: orientation,
		bounds: pitchBounds
	)
	if let multiplier { e.linePitchMultiplier = multiplier }
	return e
}

/// The line-to-line advance along the block axis, from the layout's line origins.
private func lineAdvance(_ e: PorticoTextLayoutEngine) -> CGFloat {
	let origins = e.lineOrigins()
	precondition(origins.count >= 2)
	return e.orientation == .vertical
		? abs(origins[1].x - origins[0].x)
		: abs(origins[1].y - origins[0].y)
}

// MARK: pitch scales linearly

@Test func linePitchScalesLineAdvance() {
	let text = "line one\nline two\nline three"
	let base = lineAdvance(pitchEngine(text))
	#expect(base > 0)
	#expect(abs(lineAdvance(pitchEngine(text, multiplier: 2.0)) - base * 2) < 0.5)
	#expect(abs(lineAdvance(pitchEngine(text, multiplier: 0.5)) - base * 0.5) < 0.5)
}

@Test func linePitchScalesVerticalColumns() {
	// Vertical column advance = multiplier × pitch, EXACTLY. ⛔ Until 2026-09-25 Core Text added
	// a constant font leading per column on top, so this test could only check the DELTA
	// between multipliers; with line spacing pinned (`layoutParagraphStyle`) plain linearity
	// holds and is asserted directly.
	let text = "縦書き一\n縦書き二"
	let a10 = lineAdvance(pitchEngine(text, orientation: .vertical))
	let a15 = lineAdvance(pitchEngine(text, orientation: .vertical, multiplier: 1.5))
	let a20 = lineAdvance(pitchEngine(text, orientation: .vertical, multiplier: 2.0))
	let a30 = lineAdvance(pitchEngine(text, orientation: .vertical, multiplier: 3.0))
	#expect(a15 > a10) // loosening loosens
	#expect(abs((a30 - a15) / (a20 - a10) - 1.5) < 0.05)
	#expect(abs(a20 - a10 * 2) < 0.5, "vertical columns scale linearly: \(a10) → \(a20)")
	#expect(abs(a30 - a10 * 3) < 0.5)
}

// MARK: measuredSize tracks the multiplier

@Test func measuredSizeTracksPitchMultiplier() {
	let text = "line one\nline two\nline three"
	let e = pitchEngine(text)
	let base = e.measuredSize()
	e.linePitchMultiplier = 2.0
	let doubled = e.measuredSize()
	// Block extent (height in horizontal) scales with the pitch; inline extent doesn't.
	#expect(doubled.height > base.height * 1.8)
	#expect(abs(doubled.width - base.width) < 2)
}

// MARK: 1.0 is baseline behavior (in-process A/B)

@Test func defaultMultiplierMatchesExplicitOne() {
	let text = "あいう\nえおか"
	let a = pitchEngine(text) // default
	let b = pitchEngine(text, multiplier: 1.0) // explicit set (no-op change)
	let size = CGSize(width: 200, height: 200)
	func render(_ e: PorticoTextLayoutEngine) -> [UInt8] {
		e.update(bounds: size)
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
	#expect(render(a) == render(b))
}

// MARK: clamping

@Test func linePitchMultiplierClamps() {
	let e = pitchEngine("text")
	e.linePitchMultiplier = 0.1
	#expect(e.linePitchMultiplier == 0.5)
	e.linePitchMultiplier = 10
	#expect(e.linePitchMultiplier == 3.0)
	e.linePitchMultiplier = .nan
	// NaN comparisons are false, so min/max clamp NaN to a bound rather than storing it.
	#expect(e.linePitchMultiplier.isFinite)
}

// MARK: - The pitch is the REAL column advance (2026-09-25)

private func hiraginoEngine(_ s: String, _ orientation: PorticoLayoutOrientation) -> PorticoTextLayoutEngine {
	let font = CTFontCreateWithName("HiraMinProN-W3" as CFString, 14, nil)
	return PorticoTextLayoutEngine(
		attributedString: NSAttributedString(
			string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]),
		orientation: orientation, bounds: pitchBounds)
}

/// 14 pt Hiragino columns sit 1.5 em apart — the font's natural pitch, with half-size ruby
/// fitting in the half-em gap. ⛔ Negative signature: 35 pt (2.5 em) — the ruby-line pitch
/// (2.0 em) with Core Text adding the font leading AGAIN on top (artist report, 2026-09-25).
@Test(arguments: [true, false])
func defaultPitchIsOneAndAHalfEm(vertical: Bool) {
	let e = hiraginoEngine("あああ\nいいい\nううう", vertical ? .vertical : .horizontal)
	#expect(abs(lineAdvance(e) - 21) < 0.5, "got \(lineAdvance(e))")
}
