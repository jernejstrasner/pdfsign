import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showImporter = false

    var body: some View {
        content
            .navigationTitle(windowTitle)
            .toolbar { toolbarContent }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result { open(url) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .empty:
            EmptyState(onOpen: { showImporter = true }, onDropURL: open(_:))
        case .editing, .signing:
            editor
        case .done(let url):
            SignedView(url: url)
        case .failed(let message):
            FailState(message: message, onRetry: model.reset)
        }
    }

    private var windowTitle: String {
        switch model.phase {
        case .editing, .signing: return model.sourceURL?.lastPathComponent ?? "PDFSign"
        case .done(let url): return url.lastPathComponent
        default: return "PDFSign"
        }
    }

    private func open(_ url: URL) { model.open(pickedURL: url) }

    /// True once a document is loaded — editing, signing, or already signed.
    private var hasDocument: Bool {
        switch model.phase {
        case .editing, .signing, .done: return true
        default: return false
        }
    }

    // MARK: Native toolbar — always present; controls disable when not applicable.

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showImporter = true } label: {
                Label("Open", systemImage: "doc.badge.plus")
            }
            .help("Open a PDF")
        }

        if hasDocument {
            ToolbarItem(placement: .navigation) {
                Toggle(isOn: $model.placing) {
                    Label(model.box == nil ? "Draw signature area" : "Redraw area",
                          systemImage: "rectangle.dashed")
                }
                .toggleStyle(.button)
                .help("Drag a rectangle on the page to place the signature")
                .disabled(model.phase != .editing)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if model.identities.isEmpty {
                    Text("No certificates").foregroundStyle(.secondary)
                } else {
                    Picker("Certificate", selection: $model.selectedIdentity) {
                        ForEach(model.identities) { identity in
                            Text(identity.label).tag(Optional(identity))
                        }
                    }
                    .labelsHidden()
                    .help("Signing certificate")
                    .disabled(model.phase != .editing)
                }
                Button(action: presentSavePanel) {
                    if model.phase == .signing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sign & Save…", systemImage: "signature")
                    }
                }
                .disabled(!(model.phase == .editing && model.canSign))

                if case .done(let url) = model.phase {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
            }
        }
    }

    // MARK: Editor

    private var editor: some View {
        ZStack(alignment: .top) {
            if let document = model.document {
                PDFPreview(document: document, placing: $model.placing) { box in
                    model.box = box
                    model.placing = false
                }
            }
            if model.placing {
                Text("Drag on the page to place the signature")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.placing)
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = model.defaultSaveName
        if panel.runModal() == .OK, let url = panel.url {
            model.sign(to: url)
        }
    }
}

// MARK: - States

private struct EmptyState: View {
    let onOpen: () -> Void
    let onDropURL: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Drop a PDF here")
                .font(.title3)
            Button("Open…", action: onOpen)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(targeted ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                DispatchQueue.main.async { onDropURL(url) }
            }
            return true
        }
    }
}

/// After signing: keep the signed PDF on screen with a "Signed" badge.
/// Actions (Reveal / Sign another) live in the window toolbar.
private struct SignedView: View {
    let url: URL
    @State private var document: PDFDocument?

    var body: some View {
        ZStack(alignment: .top) {
            if let document {
                PDFPreview(document: document, placing: .constant(false)) { _ in }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Label("Signed", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.green.gradient, in: Capsule())
                .shadow(radius: 5, y: 2)
                .padding(.top, 12)
        }
        .task(id: url) { document = PDFDocument(url: url) }
    }
}

private struct FailState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("Couldn't sign").font(.title3)
            Text(message)
                .foregroundStyle(.secondary)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Start over", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
