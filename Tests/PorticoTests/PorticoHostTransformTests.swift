import Testing
import Foundation
import CoreGraphics
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import Portico

// MARK: - Host transform
//
// Portico lays out in its own coordinates; a host may rotate and scale the view (a drawing app
// posing a text box). The promise: everything the system reads through view geometry — hit
// testing, selection UI, the input-method candidate anchor — follows that transform, because
// Portico converts through the view hierarchy and never through its own frame math.
//
// Each test hosts a 300×100 PorticoView centred in a 400×400 root, applies the host transform
// about the centre, and checks a point Portico reports against the same point mapped by hand.
// Negative signature: the transformed result equals the untransformed one (conversion ignored
// the transform), or lands at the unrotated corner.

private let rootSide: CGFloat = 400
private let boxSize = CGSize(width: 300, height: 100)

/// Hand-mapped expectation: `p` (root coordinates, y-DOWN, as SwiftUI lays out) rotated
/// clockwise by `degrees` on screen and scaled by `scale` about the root centre.
private func mapped(_ p: CGPoint, degrees: Double, scale: CGFloat) -> CGPoint {
	let c = CGPoint(x: rootSide / 2, y: rootSide / 2)
	let t = degrees * .pi / 180
	let x = (p.x - c.x) * scale, y = (p.y - c.y) * scale
	return CGPoint(x: c.x + x * cos(t) - y * sin(t), y: c.y + x * sin(t) + y * cos(t))
}

private func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
	abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

@MainActor
private func hosted(degrees: Double, scale: CGFloat) -> (NSWindow, PorticoTextView) {
	let engine = PorticoTextLayoutEngine(attributedString: NSAttributedString(string: "abcdefghij"))
	let root = PorticoView(engine: engine)
		.frame(width: boxSize.width, height: boxSize.height)
		.scaleEffect(scale)
		.rotationEffect(.degrees(degrees))
		.frame(width: rootSide, height: rootSide)
	let host = NSHostingView(rootView: root)
	let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: rootSide, height: rootSide),
						  styleMask: [.titled], backing: .buffered, defer: false)
	window.contentView = host
	host.layoutSubtreeIfNeeded()
	func find(_ v: NSView) -> PorticoTextView? {
		if let t = v as? PorticoTextView { return t }
		for s in v.subviews { if let t = find(s) { return t } }
		return nil
	}
	return (window, find(host)!)
}

/// Screen point → root coordinates, y-down (the space `mapped` works in).
@MainActor
private func rootPoint(fromScreen p: CGPoint, in window: NSWindow) -> CGPoint {
	let w = window.convertPoint(fromScreen: p)
	return CGPoint(x: w.x, y: rootSide - w.y)
}

// ⛔ No odd multiple of 45° here: on macOS, SwiftUI's rotation + a non-unit scale on ANY hosted
// NSView asserts in AppKit layout (`!isnan(minX)`, NSView_Layout.m) at exactly ±45°/±135° for
// some scales — a platform defect reproduced with a plain NSView, not Portico's. See README
// "Transformed hosts". iOS does not have it and keeps the diagonal cases below.
@Test(arguments: [(90.0, 1.0), (30.0, 2.0), (-120.0, 0.5)])
@MainActor func inputAnchorFollowsHostTransform(degrees: Double, scale: CGFloat) {
	let range = NSRange(location: 10, length: 0)
	let (w0, tv0) = hosted(degrees: 0, scale: 1)
	let untransformed = rootPoint(fromScreen: tv0.firstRect(forCharacterRange: range, actualRange: nil).origin, in: w0)
	let (w, tv) = hosted(degrees: degrees, scale: scale)
	let transformed = rootPoint(fromScreen: tv.firstRect(forCharacterRange: range, actualRange: nil).origin, in: w)
	#expect(!near(transformed, untransformed))
	#expect(near(transformed, mapped(untransformed, degrees: degrees, scale: scale)),
			"got \(transformed), want \(mapped(untransformed, degrees: degrees, scale: scale))")
}

#elseif canImport(UIKit)

@MainActor
private func hosted(degrees: Double, scale: CGFloat) -> (UIWindow, PorticoTextView) {
	let engine = PorticoTextLayoutEngine(attributedString: NSAttributedString(string: "abcdefghij"))
	let root = PorticoView(engine: engine)
		.frame(width: boxSize.width, height: boxSize.height)
		.scaleEffect(scale)
		.rotationEffect(.degrees(degrees))
		.frame(width: rootSide, height: rootSide)
	let controller = UIHostingController(rootView: root)
	let window = UIWindow(frame: CGRect(x: 0, y: 0, width: rootSide, height: rootSide))
	window.rootViewController = controller
	window.isHidden = false
	controller.view.frame = window.bounds
	controller.view.layoutIfNeeded()
	func find(_ v: UIView) -> PorticoTextView? {
		if let t = v as? PorticoTextView { return t }
		for s in v.subviews { if let t = find(s) { return t } }
		return nil
	}
	return (window, find(controller.view)!)
}

/// UIKit's input system asks the view for local rects (`firstRect(for:)`, `caretRect(for:)`)
/// and converts them itself, so the promise on iOS is that the view's local space maps through
/// the host transform. Checked on the caret rect, the anchor the candidate bar follows.
@Test(arguments: [(90.0, 1.0), (30.0, 2.0), (-120.0, 0.5), (45.0, 0.9), (-135.0, 0.9)])
@MainActor func inputAnchorFollowsHostTransform(degrees: Double, scale: CGFloat) {
	let (w0, tv0) = hosted(degrees: 0, scale: 1)
	let end0 = tv0.caretRect(for: tv0.endOfDocument).origin
	let untransformed = tv0.convert(end0, to: w0)
	let (w, tv) = hosted(degrees: degrees, scale: scale)
	let transformed = tv.convert(tv.caretRect(for: tv.endOfDocument).origin, to: w)
	#expect(!near(transformed, untransformed))
	#expect(near(transformed, mapped(untransformed, degrees: degrees, scale: scale)),
			"got \(transformed), want \(mapped(untransformed, degrees: degrees, scale: scale))")
}

#endif
