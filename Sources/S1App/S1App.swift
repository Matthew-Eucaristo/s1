import SwiftUI
import S1Core

/// The S1 macOS app — Liquid Glass shell over S1Core.
@available(macOS 26, *)
@main
struct S1App: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("s1") {
            ContentView(model: model)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 880, height: 620)
    }
}
