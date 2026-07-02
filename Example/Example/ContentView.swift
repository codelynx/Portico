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

		Portico is a custom, high-performance text editor engine built directly on top of Core Text.
		""")
	@State private var orientation: PorticoLayoutOrientation = .horizontal
	@State private var selection: NSRange?
	@State private var groupAnchor: CGRect?
	@State private var reading: String = ""

	private var hasSelection: Bool { (selection?.length ?? 0) > 0 }

	var body: some View {
		VStack(spacing: 12) {
			Picker("Orientation", selection: $orientation) {
				Text("Horizontal").tag(PorticoLayoutOrientation.horizontal)
				Text("Vertical").tag(PorticoLayoutOrientation.vertical)
			}
			.pickerStyle(.segmented)
			.frame(maxWidth: 300)

			// selectedRange + rubyGroupAnchor are the client contract for building ruby editing
			// on the public API: observe the selection, and get the group's anchor rect (via
			// the engine's anchorRect geometry) to float an editor beside it.
			PorticoView(text: $text, orientation: orientation,
						selectedRange: $selection, rubyGroupAnchor: $groupAnchor)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.border(Color.gray)
				.overlay(alignment: .topLeading) {
					// Selecting an existing ruby group floats the editor next to it (anchorRect).
					// x is clamped to keep the editor on-screen (matters in vertical, where columns
					// are right-aligned). Deferred to a polished tier: vertical flip-above + arrow
					// placement — a real client should use a .popover (native edge-avoidance).
					if let anchor = groupAnchor {
						GeometryReader { geo in
							let editorWidth: CGFloat = 240
							rubyEditor
								.padding(8)
								.frame(width: editorWidth)
								.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
								.overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary))
								.offset(x: max(0, min(anchor.minX, geo.size.width - editorWidth)),
										y: anchor.maxY + 4)
						}
					}
				}
				.ignoresSafeArea(.keyboard, edges: .bottom)

			// Bottom bar for adding ruby to a plain selection (no group to anchor to).
			if groupAnchor == nil {
				rubyEditor
			}
		}
		.padding()
		.onChange(of: selection) { newSelection in
			// Prefill the field with the selected group's reading, if the selection is in one.
			if let s = newSelection, s.length > 0, let group = PorticoRuby.rubyGroup(at: s.location, in: text) {
				reading = group.reading
			} else {
				reading = ""
			}
		}
	}

	/// Minimal ruby editor: select base text in the view, then set / edit / remove its reading.
	/// (Inline notation — typing `漢字《かんじ》` — also works directly in the view above.)
	private var rubyEditor: some View {
		HStack(spacing: 8) {
			// The field is the state: type/edit a reading and commit (Enter or the button) to set
			// it; commit an empty field to remove the ruby. One action covers both.
			TextField("ふりがな (reading)", text: $reading)
				.textFieldStyle(.roundedBorder)
				.disabled(!hasSelection)
				.onSubmit { applyRuby(reading) }
			Button { applyRuby(reading) } label: {
				Image(systemName: "checkmark")
			}
			.disabled(!hasSelection)
			.help("Apply reading (empty removes the ruby)")
		}
	}

	private func applyRuby(_ newReading: String?) {
		guard let s = selection, s.length > 0, s.location + s.length <= text.length else { return }
		let mutable = NSMutableAttributedString(attributedString: text)
		PorticoRuby.setRuby(newReading, for: s, in: mutable)
		text = mutable
	}
}

#Preview {
	ContentView()
}
