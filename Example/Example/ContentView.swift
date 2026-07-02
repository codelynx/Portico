//
//  ContentView.swift
//  Example
//
//  Created by Kaz Yoshikawa on 2026/05/13.
//

import SwiftUI
import Portico

struct ContentView: View {
	@State private var text = PorticoRuby.parse("""
		吾輩《わがはい》は猫《ねこ》である。名前《なまえ》はまだ無《な》い。
		どこで生《う》れたかとんと見当《けんとう》がつかぬ。何《なに》でも薄暗《うすぐら》いじめじめした所《ところ》でニャーニャー泣《な》いていた事《こと》だけは記憶《きおく》している。吾輩はここで始《はじ》めて人間《にんげん》というものを見た。

		I am a cat. As yet I have no name. I have not the faintest idea where I was born. All I remember is that I was mewing in a damp, gloomy place — and it was there, for the first time, that I set eyes on a human being.
		""")
	@State private var orientation: PorticoLayoutOrientation = .horizontal
	@State private var editing: RubyEdit?
	@State private var reading: String = ""
	@FocusState private var readingFieldFocused: Bool

	/// One in-flight ruby edit: the target range and where to anchor the popover.
	private struct RubyEdit {
		var range: NSRange
		var anchor: CGRect
	}

	var body: some View {
		VStack(spacing: 12) {
			Picker("Orientation", selection: $orientation) {
				Text("Horizontal").tag(PorticoLayoutOrientation.horizontal)
				Text("Vertical").tag(PorticoLayoutOrientation.vertical)
			}
			.pickerStyle(.segmented)
			.frame(maxWidth: 300)

			// One flow (design §7.2): select any text → native edit action (Ruby…) → this popover.
			// The framework provides the menu item via the onSelectionMenuAction seam and hands
			// back the selection range + first-segment anchor; the popover UI is ours.
			// (Inline notation — typing 漢字《かんじ》 — also works directly in the view.)
			PorticoView(text: $text, orientation: orientation,
						onSelectionMenuAction: PorticoSelectionMenuAction(title: "Ruby…") { range, anchor in
							beginEditing(range: range, anchor: anchor)
						})
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.border(Color.gray)
				.overlay(alignment: .topLeading) { rubyPopover }
				.ignoresSafeArea(.keyboard, edges: .bottom)
		}
		.padding()
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
		// Prefill only when the selection exactly matches an existing group's base — that's an edit.
		if let group = PorticoRuby.rubyGroup(at: range.location, in: text), group.base == range {
			reading = group.reading
		} else {
			reading = ""
		}
		editing = RubyEdit(range: range, anchor: anchor)
	}

	private func apply() {
		guard let edit = editing else { return }
		setRuby(reading.isEmpty ? nil : reading, for: edit.range) // cleared field removes the ruby
		editing = nil
	}

	private func setRuby(_ newReading: String?, for range: NSRange) {
		guard range.location + range.length <= text.length else { return }
		let mutable = NSMutableAttributedString(attributedString: text)
		PorticoRuby.setRuby(newReading, for: range, in: mutable)
		text = mutable
	}
}

#Preview {
	ContentView()
}
