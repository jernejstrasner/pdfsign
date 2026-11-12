import SwiftUI

struct PDFSignApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 580)
                // Agent hand-off: pick up a pending review on launch and whenever pinged.
                .task { loadPendingReview() }
                .onReceive(DistributedNotificationCenter.default().publisher(for: ReviewInbox.notification)) { _ in
                    loadPendingReview()
                    NSApp.activate()
                }
        }
        .windowResizability(.contentMinSize)
    }

    private func loadPendingReview() {
        // Don't yank a document out from under a signing in progress.
        guard model.phase != .signing, let request = ReviewInbox.consume() else { return }
        model.load(review: request)
    }
}
