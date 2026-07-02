import SwiftUI

/// A client-supplied action for the text selection menu (design §7.2 seam). When set on
/// `PorticoView`, Portico adds an item titled `title` to the native selection menu — macOS
/// right-click / iOS edit menu — whenever there's a non-empty selection; choosing it calls
/// `handler` with the selection range and its first-segment anchor rect (top-left view coords).
/// A named type (not a tuple) so it can gain fields — icon, shortcut, enablement — without
/// breaking call sites.
public struct PorticoSelectionMenuAction {
	public var title: String
	public var handler: (NSRange, CGRect) -> Void
	public init(title: String, handler: @escaping (NSRange, CGRect) -> Void) {
		self.title = title
		self.handler = handler
	}
}

#if os(macOS)
public struct PorticoView: NSViewRepresentable {
	@Binding public var text: NSAttributedString
	public var orientation: PorticoLayoutOrientation
	private var selectedRange: Binding<NSRange?>?
	private var onSelectionMenuAction: PorticoSelectionMenuAction?

	public init(text: Binding<NSAttributedString>, orientation: PorticoLayoutOrientation = .horizontal,
				selectedRange: Binding<NSRange?>? = nil,
				onSelectionMenuAction: PorticoSelectionMenuAction? = nil) {
		self._text = text
		self.orientation = orientation
		self.selectedRange = selectedRange
		self.onSelectionMenuAction = onSelectionMenuAction
	}

	public func makeNSView(context: Context) -> PorticoTextView {
		let engine = PorticoTextLayoutEngine(attributedString: text, orientation: orientation)
		let textBinding = _text
		engine.textDidChange = { newText in
			DispatchQueue.main.async {
				textBinding.wrappedValue = newText
			}
		}
		let selectionBinding = selectedRange
		engine.selectionDidChange = { range in
			DispatchQueue.main.async {
				selectionBinding?.wrappedValue = range
			}
		}
		let view = PorticoTextView(frame: .zero, layoutEngine: engine)
		view.onSelectionMenuAction = onSelectionMenuAction
		return view
	}

	public func updateNSView(_ nsView: PorticoTextView, context: Context) {
		nsView.onSelectionMenuAction = onSelectionMenuAction // refresh each render to avoid a stale closure
		if nsView.layoutEngine.attributedString != text {
			nsView.layoutEngine.update(attributedString: text)
			nsView.setNeedsDisplay(nsView.bounds)
		}
		if nsView.layoutEngine.orientation != orientation {
			nsView.layoutEngine.update(orientation: orientation)
			nsView.setNeedsDisplay(nsView.bounds)
		}
	}
}
#elseif os(iOS)
public struct PorticoView: UIViewRepresentable {
	@Binding public var text: NSAttributedString
	public var orientation: PorticoLayoutOrientation
	private var selectedRange: Binding<NSRange?>?
	private var onSelectionMenuAction: PorticoSelectionMenuAction?

	public init(text: Binding<NSAttributedString>, orientation: PorticoLayoutOrientation = .horizontal,
				selectedRange: Binding<NSRange?>? = nil,
				onSelectionMenuAction: PorticoSelectionMenuAction? = nil) {
		self._text = text
		self.orientation = orientation
		self.selectedRange = selectedRange
		self.onSelectionMenuAction = onSelectionMenuAction
	}

	public func makeUIView(context: Context) -> PorticoTextView {
		let engine = PorticoTextLayoutEngine(attributedString: text, orientation: orientation)
		let textBinding = _text
		engine.textDidChange = { newText in
			DispatchQueue.main.async {
				textBinding.wrappedValue = newText
			}
		}
		let selectionBinding = selectedRange
		engine.selectionDidChange = { range in
			DispatchQueue.main.async {
				selectionBinding?.wrappedValue = range
			}
		}
		let view = PorticoTextView(frame: .zero, layoutEngine: engine)
		view.onSelectionMenuAction = onSelectionMenuAction
		return view
	}

	public func updateUIView(_ uiView: PorticoTextView, context: Context) {
		uiView.onSelectionMenuAction = onSelectionMenuAction // refresh each render to avoid a stale closure
		if uiView.layoutEngine.attributedString != text {
			// A programmatic text change from outside the input system (e.g. setRuby). Bracket
			// it with the UITextInput notifications so UITextInteraction re-queries its cached
			// selection UI (handles/loupe) against the reflowed layout instead of leaving it
			// stale. The `!= text` guard is false during a normal typing round-trip, so this
			// fires only on genuine external changes.
			uiView.inputDelegate?.textWillChange(uiView)
			uiView.layoutEngine.update(attributedString: text)
			uiView.inputDelegate?.textDidChange(uiView)
			uiView.setNeedsDisplay()
		}
		if uiView.layoutEngine.orientation != orientation {
			// Orientation flips the whole layout, so the selection's geometry changes even
			// though its range doesn't. Bracket with the selection notifications (not the text
			// pair — this isn't a text change) so UITextInteraction re-queries handle geometry
			// and the selection stays attached to its characters instead of drifting.
			uiView.inputDelegate?.selectionWillChange(uiView)
			uiView.layoutEngine.update(orientation: orientation)
			uiView.inputDelegate?.selectionDidChange(uiView)
			uiView.setNeedsDisplay()
		}
	}
}
#endif

struct PorticoPreviewWrapper: View {
	@State private var text = NSAttributedString(string: """
		吾輩は猫である。名前はまだ無い。
		どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。吾輩はここで始めて人間というものを見た。しかもあとで聞くとそれは書生という人間中で一番獰悪な種族であったそうだ。この書生というのは時々我々を捕えて煮て食うという話である。しかしその当時は何という考もなかったから別段恐しいとも思わなかった。ただ彼の掌に載せられてスーと持ち上げられた時何だかフワフワした感じがあったばかりである。掌の上で少し落ちついて書生の顔を見たのがいわゆる人間というものの見始であろう。
		
		Portico is a custom, high-performance text editor engine built directly on top of Core Text. It mathematically handles native hit-testing, selection range tracking, and input event management, allowing for seamless toggling between horizontal and vertical layouts without compromising standard text editor capabilities.
		""")
	@State private var orientation: PorticoLayoutOrientation = .horizontal
	
	var body: some View {
		VStack(spacing: 20) {
			Picker("Orientation", selection: $orientation) {
				Text("Horizontal").tag(PorticoLayoutOrientation.horizontal)
				Text("Vertical").tag(PorticoLayoutOrientation.vertical)
			}
			.pickerStyle(.segmented)
			.frame(maxWidth: 300)
			
			PorticoView(text: $text, orientation: orientation)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.border(Color.gray)
		}
		.padding()
	}
}

#Preview {
	PorticoPreviewWrapper()
}
