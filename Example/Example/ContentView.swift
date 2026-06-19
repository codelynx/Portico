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
	
	var body: some View {
		VStack(spacing: 20) {
			Picker("Orientation", selection: $orientation) {
				Text("Horizontal").tag(PorticoLayoutOrientation.horizontal)
				Text("Vertical").tag(PorticoLayoutOrientation.vertical)
			}
			.pickerStyle(.segmented)
			.frame(maxWidth: 300)
			
			PorticoView(
				text: $text,
				orientation: orientation
			)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.border(Color.gray)
			.ignoresSafeArea(.keyboard, edges: .bottom)
		}
		.padding()
	}
}

#Preview {
	ContentView()
}
