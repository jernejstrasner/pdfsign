import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showImporter = false

    var body: some View {
        Group {
            switch model.phase {
            case .empty:
                EmptyState(onOpen: { showImporter = true }, onDropURL: open(_:))
            case .editing, .signing:
                editor
            case .done(let url):
                SignedView(url: url, onAgain: model.reset)
            case .failed(let message):
                FailState(message: message, onRetry: model.reset)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { open(url) }
        }
    }

    private func open(_ url: URL) { model.open(pickedURL: url) }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            if let document = model.document {
                PDFPreview(document: document, placing: $model.placing) { box in
                    model.box = box
                    model.placing = false
                }
            }
            Divider()
            controlBar
        }
        .overlay(alignment: .top) {
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

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                model.placing.toggle()
            } label: {
                Label(model.box == nil ? "Draw signature area" : "Redraw area",
                      systemImage: "rectangle.dashed")
            }
            .buttonStyle(.bordered)
            .tint(model.placing ? .accentColor : nil)

            if let box = model.box {
                Label("Page \(box.pageIndex + 1)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Spacer()

            if model.identities.isEmpty {
                Text("No certificates in Keychain")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                Picker("Certificate", selection: $model.selectedIdentity) {
                    ForEach(model.identities) { identity in
                        Text(identity.label).tag(Optional(identity))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }

            Button(action: presentSavePanel) {
                if model.phase == .signing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Sign & Save…")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSign || model.phase == .signing)
        }
        .padding(12)
        .background(.bar)
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
private struct SignedView: View {
    let url: URL
    let onAgain: () -> Void
    @State private var document: PDFDocument?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if let document {
                    PDFPreview(document: document, placing: .constant(false)) { _ in }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                signedBadge.padding(.top, 12)
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "doc.fill").foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Sign another", action: onAgain)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.bar)
        }
        .task(id: url) { document = PDFDocument(url: url) }
    }

    private var signedBadge: some View {
        Label("Signed", systemImage: "checkmark.seal.fill")
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.green.gradient, in: Capsule())
            .shadow(radius: 5, y: 2)
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
