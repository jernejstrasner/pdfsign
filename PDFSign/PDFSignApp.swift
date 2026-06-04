import SwiftUI

@main
struct PDFSignApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 580)
        }
        .windowResizability(.contentMinSize)
    }
}
