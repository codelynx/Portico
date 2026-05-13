//
//  ContentView.swift
//  Example
//
//  Created by Kaz Yoshikawa on 2026/05/13.
//

import SwiftUI
import Portico

struct ContentView: View {
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
			
			PorticoView(
				text: $text,
				orientation: orientation
			)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.border(Color.gray)
		}
		.padding()
	}
}

#Preview {
	ContentView()
}
