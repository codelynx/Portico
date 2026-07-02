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

@main
struct ExampleApp: App {
	var body: some Scene {
		WindowGroup {
			ContentView()
		}
		#if os(macOS)
		// Discoverable macOS entry point (⇧⌘R) beside the right-click item — sends the action up
		// the responder chain to the focused PorticoTextView, which fires its onSelectionMenuAction
		// (no-ops when there's no selection). iOS reaches the same action via the native edit menu.
		.commands {
			CommandGroup(after: .pasteboard) {
				Button("ルビ…") {
					NSApp.sendAction(#selector(PorticoTextView.performSelectionMenuAction(_:)), to: nil, from: nil)
				}
				.keyboardShortcut("r", modifiers: [.command, .shift])
			}
		}
		#endif
	}
}
