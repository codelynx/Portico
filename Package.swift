// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "Portico",
	platforms: [.macOS(.v13), .iOS(.v16)],
	products: [
		// Products define the executables and libraries a package produces, making them visible to other packages.
		.library(
			name: "Portico",
			targets: ["Portico"]
		),
	],
	targets: [
		// Targets are the basic building blocks of a package, defining a module or a test suite.
		// Targets can depend on other targets in this package and products from dependencies.
		.target(
			name: "Portico"
		),
		.testTarget(
			name: "PorticoTests",
			dependencies: ["Portico"],
			// PorticoTextLayoutEngine is @MainActor (it owns a Foundation UndoManager, which is
			// main-actor-isolated). Default the tests to the main actor so they can drive the engine
			// synchronously without a @MainActor annotation on every test.
			swiftSettings: [.defaultIsolation(MainActor.self)]
		),
	]
)
