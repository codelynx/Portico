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

/// Provider form of the selection-menu seam (0.6.0 PR-3): called AT MENU-OPEN TIME with the
/// current selection and returns the actions to show, in order — so titles can be
/// state-dependent ("縦中横" / "縦中横を解除"). The single-action `onSelectionMenuAction`
/// parameters wrap into a one-element provider; pass `selectionMenuActions:` for the full form.
public typealias PorticoSelectionMenuProvider = (NSRange) -> [PorticoSelectionMenuAction]

#if os(macOS)
public struct PorticoView: NSViewRepresentable {
	private var textBinding: Binding<NSAttributedString>?
	private var providedEngine: PorticoTextLayoutEngine?
	private var orientation: PorticoLayoutOrientation?
	private var selectedRange: Binding<NSRange?>?
	private var selectionMenuProvider: PorticoSelectionMenuProvider?
	/// Injected-engine hosts that open the editor programmatically (overlay
	/// pattern) set this so typing lands in the editor without a click/tap.
	private var focusesOnMount: Bool = false

	/// Convenience: Portico owns the engine internally, driven by the `text` binding. Undo history
	/// is **view-scoped** (lives with this view). For document/model-scoped undo that survives view
	/// teardown, use `init(engine:)` and retain the engine yourself.
	public init(text: Binding<NSAttributedString>, orientation: PorticoLayoutOrientation = .horizontal,
				selectedRange: Binding<NSRange?>? = nil,
				onSelectionMenuAction: PorticoSelectionMenuAction? = nil,
				selectionMenuActions: PorticoSelectionMenuProvider? = nil) {
		self.textBinding = text
		self.orientation = orientation
		self.selectedRange = selectedRange
		self.selectionMenuProvider = selectionMenuActions ?? onSelectionMenuAction.map { action in { _ in [action] } }
	}

	/// Model mode: the **client owns the engine** (its text, undo stack, and lifecycle), so undo is
	/// model-scoped — retain the engine and history survives view teardown. Notes:
	/// - **Out:** read `engine.attributedString`; observe `engine.textDidChange`. Passing
	///   `selectedRange` makes the view own `engine.selectionDidChange` — use the binding **or** your
	///   own `selectionDidChange`, not both.
	/// - **Orientation** is engine state; pass `orientation` (non-nil) to drive it from SwiftUI
	///   (`nil` = leave it to the engine, set `engine.update(orientation:)` yourself).
	/// - **Engine identity is fixed for the view's lifetime** — give the view a stable `.id(...)`
	///   per engine to switch documents, and use **one live view per engine**.
	public init(engine: PorticoTextLayoutEngine, orientation: PorticoLayoutOrientation? = nil,
				selectedRange: Binding<NSRange?>? = nil,
				onSelectionMenuAction: PorticoSelectionMenuAction? = nil,
				selectionMenuActions: PorticoSelectionMenuProvider? = nil,
				focusesOnMount: Bool = false) {
		self.providedEngine = engine
		self.orientation = orientation
		self.selectedRange = selectedRange
		self.selectionMenuProvider = selectionMenuActions ?? onSelectionMenuAction.map { action in { _ in [action] } }
		self.focusesOnMount = focusesOnMount
	}

	public func makeNSView(context: Context) -> PorticoTextView {
		let engine: PorticoTextLayoutEngine
		if let providedEngine {
			engine = providedEngine // wrap — never update(attributedString:) on attach (would clear undo)
			if let orientation, engine.orientation != orientation { engine.update(orientation: orientation) }
		} else {
			engine = PorticoTextLayoutEngine(attributedString: textBinding!.wrappedValue,
											 orientation: orientation ?? .horizontal)
			let textBinding = self.textBinding!
			engine.textDidChange = { newText in DispatchQueue.main.async { textBinding.wrappedValue = newText } }
		}
		if let selectionBinding = selectedRange { // only own the callback when a binding is supplied
			engine.selectionDidChange = { range in DispatchQueue.main.async { selectionBinding.wrappedValue = range } }
		}
		let view = PorticoTextView(frame: .zero, layoutEngine: engine)
		view.selectionMenuProvider = selectionMenuProvider
		view.focusesOnMount = focusesOnMount
		return view
	}

	public func updateNSView(_ nsView: PorticoTextView, context: Context) {
		nsView.selectionMenuProvider = selectionMenuProvider // refresh each render to avoid a stale closure
		let engine = nsView.layoutEngine
		// Only the binding (text:) mode syncs external text into the engine (a document reset).
		// Injected-engine mode never does — that's the client's model, and a reset would clear undo.
		if let textBinding, engine.attributedString != textBinding.wrappedValue {
			engine.update(attributedString: textBinding.wrappedValue)
			nsView.setNeedsDisplay(nsView.bounds)
		}
		if let orientation, engine.orientation != orientation {
			engine.update(orientation: orientation)
			nsView.setNeedsDisplay(nsView.bounds)
		}
	}
}
#elseif os(iOS)
public struct PorticoView: UIViewRepresentable {
	private var textBinding: Binding<NSAttributedString>?
	private var providedEngine: PorticoTextLayoutEngine?
	private var orientation: PorticoLayoutOrientation?
	private var selectedRange: Binding<NSRange?>?
	private var selectionMenuProvider: PorticoSelectionMenuProvider?
	/// Injected-engine hosts that open the editor programmatically (overlay
	/// pattern) set this so typing lands in the editor without a click/tap.
	private var focusesOnMount: Bool = false
	/// Optional accessory factory, resolved once at view creation (the bar
	/// docks above the software keyboard; see
	/// `PorticoTextView.hostInputAccessoryView`).
	private var inputAccessoryProvider: (@MainActor () -> UIView?)?
	/// Clean-state hardware-Esc hook (see `PorticoTextView.hostEscapeHandler`).
	private var onEscape: (@MainActor () -> Void)?

	/// Convenience: Portico owns the engine internally, driven by the `text` binding. Undo history
	/// is **view-scoped**. For document/model-scoped undo that survives view teardown, use
	/// `init(engine:)` and retain the engine yourself.
	public init(text: Binding<NSAttributedString>, orientation: PorticoLayoutOrientation = .horizontal,
				selectedRange: Binding<NSRange?>? = nil,
				onSelectionMenuAction: PorticoSelectionMenuAction? = nil,
				selectionMenuActions: PorticoSelectionMenuProvider? = nil) {
		self.textBinding = text
		self.orientation = orientation
		self.selectedRange = selectedRange
		self.selectionMenuProvider = selectionMenuActions ?? onSelectionMenuAction.map { action in { _ in [action] } }
	}

	/// Model mode: the **client owns the engine** (text, undo, lifecycle), so undo is model-scoped
	/// and survives view teardown while the engine is retained. Notes:
	/// - **Out:** read `engine.attributedString`; observe `engine.textDidChange`. Passing
	///   `selectedRange` makes the view own `engine.selectionDidChange` — use the binding **or** your
	///   own `selectionDidChange`, not both.
	/// - **Orientation** is engine state; pass `orientation` (non-nil) to drive it from SwiftUI —
	///   which also brackets the flip so `UITextInteraction`'s selection handles don't detach — or
	///   pass `nil` and set `engine.update(orientation:)` yourself.
	/// - **Engine identity is fixed for the view's lifetime** — give the view a stable `.id(...)`
	///   per engine to switch documents, and use **one live view per engine**.
	public init(engine: PorticoTextLayoutEngine, orientation: PorticoLayoutOrientation? = nil,
				selectedRange: Binding<NSRange?>? = nil,
				onSelectionMenuAction: PorticoSelectionMenuAction? = nil,
				selectionMenuActions: PorticoSelectionMenuProvider? = nil,
				focusesOnMount: Bool = false,
				inputAccessoryView: (@MainActor () -> UIView?)? = nil,
				onEscape: (@MainActor () -> Void)? = nil) {
		self.providedEngine = engine
		self.orientation = orientation
		self.selectedRange = selectedRange
		self.selectionMenuProvider = selectionMenuActions ?? onSelectionMenuAction.map { action in { _ in [action] } }
		self.focusesOnMount = focusesOnMount
		self.inputAccessoryProvider = inputAccessoryView
		self.onEscape = onEscape
	}

	public func makeUIView(context: Context) -> PorticoTextView {
		let engine: PorticoTextLayoutEngine
		if let providedEngine {
			engine = providedEngine // wrap — never update(attributedString:) on attach (would clear undo)
			if let orientation, engine.orientation != orientation { engine.update(orientation: orientation) }
		} else {
			engine = PorticoTextLayoutEngine(attributedString: textBinding!.wrappedValue,
											 orientation: orientation ?? .horizontal)
			let textBinding = self.textBinding!
			engine.textDidChange = { newText in DispatchQueue.main.async { textBinding.wrappedValue = newText } }
		}
		if let selectionBinding = selectedRange {
			engine.selectionDidChange = { range in DispatchQueue.main.async { selectionBinding.wrappedValue = range } }
		}
		let view = PorticoTextView(frame: .zero, layoutEngine: engine)
		view.selectionMenuProvider = selectionMenuProvider
		view.focusesOnMount = focusesOnMount
		view.hostInputAccessoryView = inputAccessoryProvider?()
		view.hostEscapeHandler = onEscape
		return view
	}

	public func updateUIView(_ uiView: PorticoTextView, context: Context) {
		uiView.selectionMenuProvider = selectionMenuProvider // refresh each render to avoid a stale closure
		// Same staleness rule for the escape hook (review F4): a host that
		// changes or removes it must take effect — `keyCommands` is computed
		// per key event, so the swap alone is sufficient. The accessory
		// VIEW deliberately stays creation-time (documented: resolved once;
		// rebuilding a UIToolbar per SwiftUI render would churn
		// reloadInputViews for nothing).
		uiView.hostEscapeHandler = onEscape
		let engine = uiView.layoutEngine
		// Only the binding (text:) mode syncs external text into the engine (a document reset).
		// Injected-engine mode never does — resetting a client's model would clear its undo stack.
		if let textBinding, engine.attributedString != textBinding.wrappedValue {
			// Bracket the external change so UITextInteraction re-queries its cached selection UI.
			uiView.inputDelegate?.textWillChange(uiView)
			engine.update(attributedString: textBinding.wrappedValue)
			uiView.inputDelegate?.textDidChange(uiView)
			uiView.setNeedsDisplay()
		}
		if let orientation, engine.orientation != orientation {
			uiView.inputDelegate?.selectionWillChange(uiView)
			engine.update(orientation: orientation)
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
