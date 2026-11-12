import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showImporter = false
    @State private var showAppearance = false

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
                ControlGroup {
                    ForEach(FieldKind.allCases) { kind in
                        Toggle(isOn: placingBinding(kind)) {
                            Label("Add \(kind.title)", systemImage: kind.systemImage)
                        }
                        .help("Add a \(kind.title.lowercased()) field — drag on the page, or click for the default size")
                    }
                }
                .disabled(model.phase != .editing)
            }

            ToolbarItem(placement: .navigation) {
                Button { showAppearance.toggle() } label: {
                    Label("Stamp", systemImage: "pencil.and.scribble")
                }
                .help("Signature image, date and text stamped with the signature")
                .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                    AppearanceEditor(model: model)
                }
                .disabled(model.phase != .editing)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if model.identities.isEmpty {
                    Text("No certificates").foregroundStyle(.secondary)
                } else {
                    Picker("Certificate", selection: $model.selectedIdentity) {
                        if model.selectedIdentity == nil {
                            Text("Choose certificate…").tag(SigningIdentity?.none)
                        }
                        ForEach(model.identities) { identity in
                            Text(identity.label).tag(Optional(identity))
                        }
                    }
                    .labelsHidden()
                    .help(model.selectedIdentity.map(certificateHelp) ?? "Signing certificate")
                    .disabled(model.phase != .editing)
                }
                Button(action: presentSavePanel) {
                    if model.phase == .signing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sign & Save…", systemImage: "signature")
                    }
                }
                .help(model.signProblems.isEmpty ? "Sign and save a copy"
                      : model.signProblems.joined(separator: "\n"))
                .disabled(!(model.phase == .editing && model.canSign))

                if case .done(let url) = model.phase {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
            }
        }
    }

    private func placingBinding(_ kind: FieldKind) -> Binding<Bool> {
        Binding(get: { model.placingKind == kind },
                set: { model.placingKind = $0 ? kind : nil })
    }

    private func certificateHelp(_ identity: SigningIdentity) -> String {
        var lines = [identity.details.subject]
        if let issuer = identity.details.issuer { lines.append("Issued by \(issuer)") }
        if let until = identity.details.notAfter {
            lines.append("Valid until \(until.formatted(date: .abbreviated, time: .omitted))")
        }
        lines.append("SHA-256 \(identity.fingerprint.prefix(16))…")
        return lines.joined(separator: "\n")
    }

    // MARK: Editor

    private var editor: some View {
        ZStack {
            if let document = model.document {
                PDFPreview(document: document,
                           fields: model.fields,
                           selectedFieldID: model.selectedFieldID,
                           placingKind: model.phase == .editing ? model.placingKind : nil,
                           slots: model.phase == .editing ? model.availableSlots : [],
                           appearance: model.stampAppearance,
                           handlers: handlers)
            }
            VStack {
                if let kind = model.placingKind {
                    hint("Drag on the page to place the \(kind.title.lowercased()) field, or click for the default size")
                } else if let banner = model.banner {
                    hint(banner)
                } else if !model.availableSlots.isEmpty, !model.fields.contains(where: \.isFormField) {
                    hint(model.availableSlots.count == 1
                         ? "This document has a signature field — click it to sign there"
                         : "This document has \(model.availableSlots.count) signature fields — click the one to sign")
                }
                Spacer()
                if model.phase == .editing, model.selectedField != nil {
                    FieldInspector(model: model)
                        .padding(10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.default, value: model.placingKind)
        .animation(.default, value: model.selectedFieldID)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var handlers: FieldEditingHandlers {
        FieldEditingHandlers(
            add: { id, kind, page, rect in model.addField(id: id, kind: kind, pageIndex: page, rect: rect) },
            move: { id, rect in model.moveField(id, to: rect) },
            select: { model.selectedFieldID = $0 },
            delete: { model.deleteField($0) },
            placingDone: { model.placingKind = nil },
            fillSlot: { model.fillSlot($0) })
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = model.defaultSaveName
        if let dir = model.suggestedOutputURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.sign(to: url)
        }
    }
}

/// Edits the selected field: its text or date format, plus duplicate / every page / delete.
private struct FieldInspector: View {
    @Bindable var model: AppModel
    @FocusState private var textFocused: Bool

    var body: some View {
        if let field = model.selectedField {
            HStack(spacing: 10) {
                Label(field.kind.title, systemImage: field.kind.systemImage)
                    .font(.headline)
                Text("page \(field.pageIndex + 1)")
                    .foregroundStyle(.secondary)

                switch field.kind {
                case .text:
                    TextField("Text to stamp", text: Binding(
                        get: { model.selectedField?.text ?? "" },
                        set: { model.selectedField?.text = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .focused($textFocused)
                        .frame(minWidth: 180)
                case .date:
                    TextField("Format", text: Binding(
                        get: { model.selectedField?.dateFormat ?? "" },
                        set: { model.selectedField?.dateFormat = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .help("Date format, e.g. yyyy-MM-dd or d. M. yyyy — filled in when you sign")
                    Text(field.displayText() ?? "")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                case .signature:
                    Text(signatureRole(field))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button { model.duplicateSelected() } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .keyboardShortcut("d")
                .help("Duplicate (⌘D)")
                if (model.document?.pageCount ?? 1) > 1 {
                    Button { model.copySelectedToAllPages() } label: {
                        Label("Every Page", systemImage: "square.stack")
                    }
                    .help("Copy this field to the same spot on every other page")
                }
                Button(role: .destructive) { model.deleteField(field.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete field (⌫)")
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .frame(maxWidth: 820)
            .onAppear(perform: focusEmptyText)
            .onChange(of: model.selectedFieldID) { focusEmptyText() }
        }
    }

    private func signatureRole(_ field: PlacedField) -> String {
        if let name = field.formFieldName { return "Signs the document's \u{201C}\(name)\u{201D} field" }
        let primary = model.fields.first(where: \.isFormField) ?? model.fields.first { $0.kind == .signature }
        return primary?.id == field.id ? "Digital signature" : "Additional stamp of the same signature"
    }

    /// A freshly placed text field is useless until typed into — put the cursor there.
    private func focusEmptyText() {
        if let f = model.selectedField, f.kind == .text, f.text.isEmpty { textFocused = true }
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
                PDFPreview(document: document)
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
