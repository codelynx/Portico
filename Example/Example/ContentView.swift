//
//  ContentView.swift
//  Example
//
//  Created by Kaz Yoshikawa on 2026/05/13.
//

import SwiftUI
import Combine
import Portico

struct ContentView: View {
	// The client owns the engine → **model-scoped undo**: history survives view teardown, and ⌘Z /
	// Edit ▸ Undo / shake / the buttons below all drive it. Ruby edits go through engine.setRuby
	// (undoable) instead of replacing the whole document. (A real app should hold the engine in a
	// view model / ancestor `@StateObject`-style holder rather than a leaf `@State`; here it's fine —
	// ContentView is the root and rarely re-inits.)
	@State private var engine = PorticoTextLayoutEngine(attributedString: PorticoRuby.parse("""
		吾輩《わがはい》は猫《ねこ》である。名前《なまえ》はまだ無《な》い。
		どこで生《う》れたかとんと見当《けんとう》がつかぬ。何《なに》でも薄暗《うすぐら》いじめじめした所《ところ》でニャーニャー泣《な》いていた事《こと》だけは記憶《きおく》している。吾輩はここで始《はじ》めて人間《にんげん》というものを見た。
		発行は平成12年3月10日、第158刷。まさか!?

		I am a cat. As yet I have no name. I have not the faintest idea where I was born. All I remember is that I was mewing in a damp, gloomy place — and it was there, for the first time, that I set eyes on a human being.
		"""))
	@State private var orientation: PorticoLayoutOrientation = .horizontal
	@State private var editing: RubyEdit?
	@State private var reading: String = ""
	@FocusState private var readingFieldFocused: Bool
	@State private var canUndo = false
	@State private var canRedo = false
	// 0.4.0 manga-lettering surface demo: outline (縁取り), line pitch, live measurement.
	@State private var outlineEnabled = false
	@State private var outlineWidth: CGFloat = 2
	@State private var pitchMultiplier: CGFloat = 1.0
	@State private var measured: CGSize = .zero

	/// One in-flight ruby edit: the target range and where to anchor the popover.
	private struct RubyEdit {
		var range: NSRange
		var anchor: CGRect
	}

	var body: some View {
		VStack(spacing: 12) {
			HStack(spacing: 12) {
				Picker("Orientation", selection: $orientation) {
					Text("Horizontal").tag(PorticoLayoutOrientation.horizontal)
					Text("Vertical").tag(PorticoLayoutOrientation.vertical)
				}
				.pickerStyle(.segmented)
				.frame(maxWidth: 300)
				Spacer()
				Button { performUndo() } label: { Image(systemName: "arrow.uturn.backward") }
					.help("Undo (also ⌘Z)")
					.disabled(!canUndo)
				Button { performRedo() } label: { Image(systemName: "arrow.uturn.forward") }
					.help("Redo")
					.disabled(!canRedo)
			}

			// 0.4.0 manga-lettering controls: white 縁取り (visible against the gray canvas
			// below), line-pitch multiplier, and the live measuredSize readout.
			HStack(spacing: 12) {
				Toggle("縁取り", isOn: $outlineEnabled)
				Slider(value: $outlineWidth, in: 0.5...6) { Text("Edge") }
					.frame(maxWidth: 140)
					.disabled(!outlineEnabled)
					.help("Outline width (points)")
				Slider(value: $pitchMultiplier, in: 0.5...3) { Text("Pitch") }
					.frame(maxWidth: 140)
					.help("Line-pitch multiplier")
				Spacer()
				if measured != .zero {
					Text("fits \(Int(measured.width))×\(Int(measured.height))")
						.font(.caption.monospacedDigit())
						.foregroundStyle(.secondary)
						.help("measuredSize(inlineExtent: nil) — live")
				}
			}

			// engine: mode. Select any text → native edit menu → Ruby… opens this popover (one
			// undoable engine.setRuby step) or 縦中横 toggles the selection (0.6.0: the provider is
			// evaluated at menu-open, so the title reads 縦中横／縦中横を解除 from current state;
			// try it in Vertical on "12" / "158" / "!?"). Typing 漢字《かんじ》 also converts live —
			// the demo opts in below (default is off; paste always imports 《》).
			PorticoView(engine: engine, orientation: orientation,
						selectionMenuActions: { range in
							[
								PorticoSelectionMenuAction(title: "Ruby…") { range, anchor in
									beginEditing(range: range, anchor: anchor)
								},
								PorticoSelectionMenuAction(
									title: engine.tateChuYokoToggle(for: range) == .release
										? "縦中横を解除" : "縦中横"
								) { range, _ in
									engine.performTateChuYokoToggle(for: range)
								},
							]
						})
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Color(white: 0.85)) // shows off the white outline halo
				.border(Color.gray)
				.overlay(alignment: .topLeading) { rubyPopover }
				.ignoresSafeArea(.keyboard, edges: .bottom)
		}
		.padding()
		.onChange(of: outlineEnabled) { _ in applyOutline() }
		.onChange(of: outlineWidth) { _ in applyOutline() }
		.onChange(of: pitchMultiplier) { _ in
			engine.linePitchMultiplier = pitchMultiplier
			refreshMeasured()
		}
		.onChange(of: orientation) { _ in
			// The view applies the orientation to the engine; the measurement readout
			// must follow (measured axes swap between H and V).
			refreshMeasured()
		}
		.onAppear {
			// Client observation seam (distinct from the view's internal repaint slot):
			// keep the measurement readout live as the user types.
			engine.textDidChange = { _ in refreshMeasured() }
			// The demo opts into live Aozora typing (default off since 0.6.0 — the owned
			// notation is [[…]]; paste imports 《》 regardless of this flag).
			engine.importsAozoraRubyWhileTyping = true
			refreshMeasured()
		}
		// The engine isn't Observable (by design), but its UndoManager broadcasts state. Refresh the
		// buttons off the notifications that fire **after the stack settles** — a group closing (a new
		// step registered), and undo/redo transitions. (Not `.NSUndoManagerCheckpoint`: at group-close
		// it can fire before the group lands on the stack, so `canUndo` reads a step stale — the "Undo
		// greyed out right after an edit" symptom.) This is the pattern a client uses to reflect
		// canUndo/canRedo without any engine API.
		.onReceive(Publishers.MergeMany([
			NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup, object: engine.undoManager),
			NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange, object: engine.undoManager),
			NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange, object: engine.undoManager),
		])) { _ in
			refreshUndoState()
		}
		// Bridge the engine up to the app's Edit ▸ Undo/Redo commands (see ExampleApp): SwiftUI's
		// default Undo/Redo drive their own environment manager, not ours, so the app replaces them
		// with commands that drive this engine.
		.focusedSceneValue(\.porticoEngine, engine)
	}

	private func applyOutline() {
		engine.outline = outlineEnabled
			? PorticoTextOutline(width: outlineWidth, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
			: nil
	}

	private func refreshMeasured() {
		measured = engine.measuredSize()
	}

	private func performUndo() {
		guard engine.markedRange == nil else { return } // don't undo mid-composition (matches the framework's own gate)
		editing = nil                                    // drop any open popover — undo may invalidate its range
		engine.undoManager.undo()
		refreshUndoState()
	}

	private func performRedo() {
		guard engine.markedRange == nil else { return }
		editing = nil
		engine.undoManager.redo()
		refreshUndoState()
	}

	private func refreshUndoState() {
		canUndo = engine.undoManager.canUndo
		canRedo = engine.undoManager.canRedo
	}

	/// A floating editor anchored to the selection. Prefers to sit below the anchor but flips
	/// above when that would clip the bottom edge, then clamps both axes into the frame.
	/// (A production client should use a native `.popover` for edge-avoidance; this is the demo's
	/// own placement.)
	@ViewBuilder private var rubyPopover: some View {
		if let edit = editing {
			GeometryReader { geo in
				let editorWidth: CGFloat = 280
				let editorHeight: CGFloat = 56
				let belowY = edit.anchor.maxY + 4
				let aboveY = edit.anchor.minY - editorHeight - 4
				let preferredY = (belowY + editorHeight <= geo.size.height) ? belowY : aboveY
				rubyEditor(edit)
					.padding(8)
					.frame(width: editorWidth, height: editorHeight)
					.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
					.overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary))
					.offset(x: max(0, min(edit.anchor.minX, geo.size.width - editorWidth)),
							y: max(0, min(preferredY, geo.size.height - editorHeight)))
			}
		}
	}

	private func rubyEditor(_ edit: RubyEdit) -> some View {
		HStack(spacing: 8) {
			// The field is the state: type a ruby and commit (Enter or ✓) to set it; clear the
			// field and commit to remove the ruby. One action covers set / edit / remove.
			TextField("ruby", text: $reading)
				.textFieldStyle(.roundedBorder)
				.focused($readingFieldFocused)
				.onAppear { readingFieldFocused = true } // type immediately — no extra tap
				.onSubmit { apply() }
			Button { apply() } label: { Image(systemName: "checkmark") }
				.help("Apply — a cleared field removes the ruby")
			Button { editing = nil } label: { Image(systemName: "xmark") }
				.help("Cancel")
		}
	}

	/// Open the editor for a menu-triggered selection. Prefill only when the selection **exactly**
	/// matches an existing group's base (§7.2) — that's an edit. Any other selection (plain /
	/// partial / spanning) starts empty and adds or replaces over the selection on apply.
	private func beginEditing(range: NSRange, anchor: CGRect) {
		guard editing == nil else { return } // ignore re-trigger (e.g. ⇧⌘R) while the editor is open
		if let group = PorticoRuby.rubyGroup(at: range.location, in: engine.attributedString), group.base == range {
			reading = group.reading
		} else {
			reading = ""
		}
		editing = RubyEdit(range: range, anchor: anchor)
	}

	private func apply() {
		guard let edit = editing else { return }
		// One undoable step through the engine (cleared field removes), not a document replacement.
		engine.setRuby(reading.isEmpty ? nil : reading, for: edit.range)
		editing = nil
	}
}

#Preview {
	ContentView()
}
