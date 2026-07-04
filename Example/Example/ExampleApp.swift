//
//  ExampleApp.swift
//  Example
//
//  Created by Kaz Yoshikawa on 2026/05/13.
//

import SwiftUI
import Portico
#if os(macOS)
import AppKit
#endif

// Bridge the focused view's engine up to the app's menu commands.
private struct PorticoEngineFocusedKey: FocusedValueKey {
	typealias Value = PorticoTextLayoutEngine
}
extension FocusedValues {
	var porticoEngine: PorticoTextLayoutEngine? {
		get { self[PorticoEngineFocusedKey.self] }
		set { self[PorticoEngineFocusedKey.self] = newValue }
	}
}

@main
struct ExampleApp: App {
	// Portico vends its engine's undo manager up the AppKit responder chain (NSView.undoManager),
	// but SwiftUI's default Edit ▸ Undo / ⌘Z drive `@Environment(\.undoManager)` — a *different*
	// manager our edits never touch — so they do nothing. A SwiftUI app wrapping a custom text view
	// must therefore replace the Undo/Redo commands with ones that drive the engine directly. The
	// engine is bridged up from the focused view via `focusedSceneValue`.
	@FocusedValue(\.porticoEngine) private var engine: PorticoTextLayoutEngine?

	var body: some Scene {
		WindowGroup {
			ContentView()
		}
		.commands {
			CommandGroup(replacing: .undoRedo) {
				// Disable while composing too, not just the action guard — else the menu item reads
				// enabled but no-ops mid-IME. (The menu re-evaluates .disabled on open, so it reflects
				// current markedRange even though the engine isn't Observable.)
				Button("Undo") { undo() }
					.keyboardShortcut("z", modifiers: .command)
					.disabled(engine == nil || engine?.markedRange != nil)
				Button("Redo") { redo() }
					.keyboardShortcut("z", modifiers: [.command, .shift])
					.disabled(engine == nil || engine?.markedRange != nil)
			}
			#if os(macOS)
			// Discoverable macOS entry points beside the right-click items. Ruby… (⇧⌘R) sends the
			// selector up the responder chain to the focused PorticoTextView; a bare send (no menu
			// item index) invokes the provider's FIRST action, which is Ruby…. 縦中横 (⇧⌘T) drives
			// the engine API directly — its title needs the menu-open selection state, which the
			// bridged engine gives us for free. iOS reaches both via the native edit menu.
			CommandGroup(after: .pasteboard) {
				Button("Ruby…") {
					NSApp.sendAction(#selector(PorticoTextView.performSelectionMenuAction(_:)), to: nil, from: nil)
				}
				.keyboardShortcut("r", modifiers: [.command, .shift])
				Button(tateChuYokoTitle) { toggleTateChuYoko() }
					.keyboardShortcut("t", modifiers: [.command, .shift])
					.disabled(engine == nil || (engine?.selectionRange?.length ?? 0) == 0)
			}
			#endif
		}
	}

	// Guard on markedRange to match the framework's own rule — don't undo mid-IME-composition.
	private func undo() { if let engine, engine.markedRange == nil { engine.undoManager.undo() } }
	private func redo() { if let engine, engine.markedRange == nil { engine.undoManager.redo() } }

	#if os(macOS)
	/// State-dependent verb, read at menu-open (like `.disabled` above): 解除 when the whole
	/// selection already renders 縦中横, apply otherwise (mixed = apply-wins).
	private var tateChuYokoTitle: String {
		guard let engine, let selection = engine.selectionRange, selection.length > 0,
			  engine.tateChuYokoToggle(for: selection) == .release else { return "縦中横" }
		return "縦中横を解除"
	}
	private func toggleTateChuYoko() {
		guard let engine, let selection = engine.selectionRange, selection.length > 0 else { return }
		engine.performTateChuYokoToggle(for: selection)
	}
	#endif
}
