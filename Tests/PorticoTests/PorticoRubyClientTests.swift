// Client-perspective tests: plain `import Portico` (NOT @testable), so these can
// only touch the public API. They guarantee the ruby feature stays reachable from
// client code that links the library, exactly as the Example app does.
import Testing
import Foundation
import CoreText
import Portico

@Test func clientCanAuthorRubyFromNotation() {
	// Author ruby the way a client would: Aozora notation in, attributed string out.
	let attributed = PorticoRuby.parse("漢字《かんじ》とルビ")
	#expect(attributed.string == "漢字とルビ")

	// The CTRubyAnnotation is reachable through public Foundation/CoreText APIs.
	let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
	#expect(attributed.attribute(rubyKey, at: 0, effectiveRange: nil) != nil)
}

@Test func clientCanPersistRubyViaSerialize() {
	// A client can round-trip ruby to text for saving and reload it later.
	let original = "吾輩《わがはい》は猫《ねこ》"
	let saved = PorticoRuby.serialize(PorticoRuby.parse(original))
	let reloaded = PorticoRuby.parse(saved)
	#expect(reloaded.string == "吾輩は猫")
	let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
	#expect(reloaded.attribute(rubyKey, at: 0, effectiveRange: nil) != nil)
}

@Test func clientCanFeedRubyIntoEngine() {
	// The authored string drops straight into the public layout engine.
	let attributed = PorticoRuby.parse("吾輩《わがはい》は猫《ねこ》")
	let engine = PorticoTextLayoutEngine(
		attributedString: attributed,
		orientation: .vertical,
		bounds: CGSize(width: 200, height: 200)
	)
	#expect(engine.attributedString.string == "吾輩は猫")

	// Updating the engine's text with freshly-parsed ruby also works.
	engine.update(attributedString: PorticoRuby.parse("日本語《にほんご》"))
	#expect(engine.attributedString.string == "日本語")
}
