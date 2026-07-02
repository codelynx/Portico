import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import Portico

// MARK: - Measurement tests (PR-2: measuredSize(inlineExtent:))
//
// Acceptance per Docs/MangaLettering-Extensions-Plan.md PR-2: fits (layout at the
// measured size shows the full string), tightness (shrinking either dimension
// truncates), works on a never-laid-out engine, constrained wrapping, ceiling,
// empty → .zero. All fixtures below construct engines with bounds .zero so every
// measurement exercises the never-laid-out path.

private func freshEngine(
	_ attributed: NSAttributedString,
	orientation: PorticoLayoutOrientation
) -> PorticoTextLayoutEngine {
	// bounds .zero: the engine has never laid out when measuredSize is called.
	PorticoTextLayoutEngine(attributedString: attributed, orientation: orientation, bounds: .zero)
}

private func freshEngine(
	_ s: String,
	orientation: PorticoLayoutOrientation
) -> PorticoTextLayoutEngine {
	freshEngine(NSAttributedString(string: s), orientation: orientation)
}

/// Lays the engine out at `size` and reports how much of the string is visible.
private func visibleLength(_ e: PorticoTextLayoutEngine, at size: CGSize) -> Int {
	e.update(bounds: size)
	return e.visibleStringRangeLength()
}

// MARK: basics

@Test func measuredSizeEmptyStringIsZero() {
	#expect(freshEngine("", orientation: .horizontal).measuredSize() == .zero)
	#expect(freshEngine("", orientation: .vertical).measuredSize() == .zero)
}

@Test func measuredSizeIsIntegral() {
	let m = freshEngine("hello world", orientation: .horizontal).measuredSize()
	#expect(m.width == m.width.rounded(.up))
	#expect(m.height == m.height.rounded(.up))
}

// MARK: fits + tightness, horizontal

@Test func measuredSizeHorizontalFitsAndIsTight() {
	let text = "hello world"
	let full = (text as NSString).length // UTF-16 units, matching visibleStringRangeLength
	let e = freshEngine(text, orientation: .horizontal)
	let m = e.measuredSize() // never-laid-out engine
	#expect(m.width > 0 && m.height > 0)

	#expect(visibleLength(e, at: m) == full) // fits
	#expect(visibleLength(e, at: CGSize(width: m.width - 2, height: m.height)) < full) // width-tight
	#expect(visibleLength(e, at: CGSize(width: m.width, height: m.height - 2)) < full) // height-tight
}

@Test func measuredSizeManualBreaksFit() {
	let text = "line one\nline two\nline three"
	let full = (text as NSString).length
	let e = freshEngine(text, orientation: .horizontal)
	let m = e.measuredSize()
	#expect(visibleLength(e, at: m) == full)
	#expect(visibleLength(e, at: CGSize(width: m.width, height: m.height - 2)) < full)
}

// MARK: fits + tightness, vertical with ruby (incl. long reading)

@Test func measuredSizeVerticalWithRubyFitsAndIsTight() {
	let attributed = PorticoRuby.parse("吾輩《わがはい》は猫である。名前はまだ無い。")
	let e = freshEngine(attributed, orientation: .vertical)
	let m = e.measuredSize()
	let full = attributed.length

	#expect(visibleLength(e, at: m) == full)
	#expect(visibleLength(e, at: CGSize(width: m.width - 2, height: m.height)) < full) // block-tight (columns)
	#expect(visibleLength(e, at: CGSize(width: m.width, height: m.height - 2)) < full) // inline-tight
}

@Test func measuredSizeLongReadingRubyFits() {
	// Reading much wider than its base — the classic overhang fixture.
	let attributed = PorticoRuby.parse("｜社会《ソサイエティー》を見る")
	for orientation in [PorticoLayoutOrientation.horizontal, .vertical] {
		let e = freshEngine(attributed, orientation: orientation)
		let m = e.measuredSize()
		#expect(visibleLength(e, at: m) == attributed.length)
	}
}

// MARK: constrained wrapping

@Test func measuredSizeConstrainedWrapsHorizontal() {
	let text = "aaa bbb ccc ddd eee fff ggg hhh"
	let full = (text as NSString).length
	let e = freshEngine(text, orientation: .horizontal)
	let natural = e.measuredSize()
	let constrained = e.measuredSize(inlineExtent: natural.width / 3)

	#expect(constrained.width <= ceil(natural.width / 3)) // respects the wrap constraint
	#expect(constrained.height > natural.height) // block extent grows (wrapped lines)
	#expect(visibleLength(e, at: constrained) == full) // still fits everything
}

@Test func measuredSizeConstrainedWrapsVertical() {
	let text = "これは長い縦書きの文章でありまして折り返しが必要です"
	let full = (text as NSString).length
	let e = freshEngine(text, orientation: .vertical)
	let natural = e.measuredSize()
	let constrained = e.measuredSize(inlineExtent: natural.height / 3)

	#expect(constrained.height <= ceil(natural.height / 3)) // inline extent = height in vertical
	#expect(constrained.width > natural.width) // block extent = width grows (more columns)
	#expect(visibleLength(e, at: constrained) == full)
}

// MARK: spacing skips the tighten (perf guard path) but still fits via end-verification

@Test func measuredSizeWithParagraphSpacingFits() {
	let style = NSMutableParagraphStyle()
	style.paragraphSpacing = 12
	style.paragraphSpacingBefore = 6
	let attributed = NSAttributedString(
		string: "first paragraph\nsecond paragraph\nthird paragraph",
		attributes: [.paragraphStyle: style]
	)
	let e = freshEngine(attributed, orientation: .horizontal)
	let m = e.measuredSize()
	#expect(visibleLength(e, at: m) == attributed.length)
}

@Test func measuredSizeWithLineSpacingFits() {
	let style = NSMutableParagraphStyle()
	style.lineSpacing = 8
	let attributed = NSAttributedString(
		string: "aaa bbb ccc ddd eee fff ggg hhh",
		attributes: [.paragraphStyle: style]
	)
	let e = freshEngine(attributed, orientation: .horizontal)
	// Constrain so the text wraps — line spacing then contributes real block extent.
	let m = e.measuredSize(inlineExtent: 120)
	#expect(visibleLength(e, at: m) == attributed.length)
}

// MARK: invalid inline extents are treated as unconstrained (documented)

@Test func measuredSizeInvalidInlineExtentIsUnconstrained() {
	let e = freshEngine("hello world wrap wrap wrap", orientation: .horizontal)
	let natural = e.measuredSize()
	#expect(e.measuredSize(inlineExtent: -5) == natural)
	#expect(e.measuredSize(inlineExtent: 0) == natural)
	#expect(e.measuredSize(inlineExtent: .nan) == natural)
	#expect(e.measuredSize(inlineExtent: .infinity) == natural)
}
