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
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Install Command Line Tool & Agent Skill…", action: installAgentTools)
            }
        }
    }

    private func installAgentTools() {
        let alert = NSAlert()
        do {
            let r = try Installer.install()
            alert.messageText = "Installed"
            var lines: [String] = []
            if let command = r.command { lines.append("Command: \(command) — run `pdfsign help`.") }
            lines += r.skills.map { "Agent skill: \($0)" }
            lines += r.notes
            alert.informativeText = lines.joined(separator: "\n\n")
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    private func loadPendingReview() {
        // Don't yank a document out from under a signing in progress.
        guard model.phase != .signing, let request = ReviewInbox.consume() else { return }
        model.load(review: request)
    }
}
