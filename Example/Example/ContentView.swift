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

			// Selection is observed via the selectedRange binding — the client contract for
			// building ruby editing on the public API.
			PorticoView(text: $text, orientation: orientation, selectedRange: $selection)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.border(Color.gray)
				.ignoresSafeArea(.keyboard, edges: .bottom)

			rubyEditor
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
			TextField("ふりがな (reading)", text: $reading)
				.textFieldStyle(.roundedBorder)
				.disabled(!hasSelection)
			Button("Set") { applyRuby(reading) }
				.disabled(!hasSelection || reading.trimmingCharacters(in: .whitespaces).isEmpty)
			Button("Remove") { applyRuby(nil) }
				.disabled(!hasSelection)
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
