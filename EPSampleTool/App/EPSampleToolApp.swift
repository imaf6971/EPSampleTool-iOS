import SwiftUI

@main
struct EPSampleToolApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .tint(Theme.accent)
                .task { model.start() }
        }
    }
}

enum Theme {
    static let accent = Color(red: 1.0, green: 0.36, blue: 0.13)
    static let slotFont = Font.system(.body, design: .monospaced).weight(.semibold)
}
