import SwiftUI

#if os(macOS)
public struct PorticoView: NSViewRepresentable {
	@Binding public var text: NSAttributedString
	public var orientation: PorticoLayoutOrientation
	private var selectedRange: Binding<NSRange?>?
	private var rubyGroupAnchor: Binding<CGRect?>?

	public init(text: Binding<NSAttributedString>, orientation: PorticoLayoutOrientation = .horizontal,
				selectedRange: Binding<NSRange?>? = nil, rubyGroupAnchor: Binding<CGRect?>? = nil) {
		self._text = text
		self.orientation = orientation
		self.selectedRange = selectedRange
		self.rubyGroupAnchor = rubyGroupAnchor
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
		let anchorBinding = rubyGroupAnchor
		engine.selectionDidChange = { [weak engine] range in
			DispatchQueue.main.async {
				selectionBinding?.wrappedValue = range
				anchorBinding?.wrappedValue = engine?.rubyAnchorRectForSelection()
			}
		}
		return PorticoTextView(frame: .zero, layoutEngine: engine)
	}
	
	public func updateNSView(_ nsView: PorticoTextView, context: Context) {
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
	private var rubyGroupAnchor: Binding<CGRect?>?

	public init(text: Binding<NSAttributedString>, orientation: PorticoLayoutOrientation = .horizontal,
				selectedRange: Binding<NSRange?>? = nil, rubyGroupAnchor: Binding<CGRect?>? = nil) {
		self._text = text
		self.orientation = orientation
		self.selectedRange = selectedRange
		self.rubyGroupAnchor = rubyGroupAnchor
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
		let anchorBinding = rubyGroupAnchor
		engine.selectionDidChange = { [weak engine] range in
			DispatchQueue.main.async {
				selectionBinding?.wrappedValue = range
				anchorBinding?.wrappedValue = engine?.rubyAnchorRectForSelection()
			}
		}
		return PorticoTextView(frame: .zero, layoutEngine: engine)
	}
	
	public func updateUIView(_ uiView: PorticoTextView, context: Context) {
		if uiView.layoutEngine.attributedString != text {
			uiView.layoutEngine.update(attributedString: text)
			uiView.setNeedsDisplay()
		}
		if uiView.layoutEngine.orientation != orientation {
			uiView.layoutEngine.update(orientation: orientation)
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
