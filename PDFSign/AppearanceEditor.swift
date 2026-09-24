import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Popover for customizing what the visible signature stamp looks like:
/// signature image (drawn or imported), date toggle, and a free-text line.
struct AppearanceEditor: View {
    @Bindable var model: AppModel
    @State private var drawing = false
    @State private var canvasID = UUID()
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            signatureSection
            Divider()
            Toggle("Show date", isOn: $model.includeDate)
            LabeledContent("Text") {
                TextField("Additional text (optional)", text: $model.customText)
            }
            Divider()
            StampPreview(model: model)
        }
        .padding(14)
        .frame(width: 360)
        .background(WindowReader { hostWindow = $0 })
    }

    @ViewBuilder
    private var signatureSection: some View {
        if drawing {
            SignatureCanvas { image in
                model.signatureImage = image
                drawing = false
            }
            .id(canvasID)  // fresh canvas when "Clear" bumps the id
            .frame(height: 150)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            HStack {
                Button("Clear") { canvasID = UUID() }
                Spacer()
                Button("Done") { drawing = false }
            }
        } else if let image = model.signatureImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(maxHeight: 90)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            HStack {
                Button("Redraw…") { drawing = true }
                Button("Import…") { importImage() }
                Spacer()
                Button("Remove", role: .destructive) { model.signatureImage = nil }
            }
        } else {
            HStack {
                Button("Draw Signature…") { drawing = true }
                Button("Import Image…") { importImage() }
            }
            Text("No signature image — a badge is stamped instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        panel.allowsMultipleSelection = false
        let apply = {
            guard let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            model.signatureImage = image
        }
        // Attach the panel to the popover's window — a modal panel would steal key
        // status and dismiss the (transient) popover; a sheet keeps it alive.
        if let hostWindow {
            panel.beginSheetModal(for: hostWindow) { if $0 == .OK { apply() } }
        } else if panel.runModal() == .OK {
            apply()
        }
    }
}

/// Captures the window hosting this view (the popover panel) so dialogs can be
/// attached to it as sheets.
private struct WindowReader: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

/// Live mock of the stamp the signing engine will draw into the PDF.
private struct StampPreview: View {
    @Bindable var model: AppModel

    private var dateString: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: Date()) + " UTC"
    }

    var body: some View {
        HStack(spacing: 10) {
            if let image = model.signatureImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(maxWidth: 110, maxHeight: 40)
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                // Helvetica to match the stamped output (see StampAnnotation).
                Text(model.selectedIdentity.map { "Signed by \($0.label)" } ?? "Digitally signed")
                    .font(.custom("Helvetica-Bold", size: 12))
                if model.includeDate {
                    Text(dateString).font(.custom("Helvetica", size: 10))
                }
                if !model.customText.isEmpty {
                    Text(model.customText).font(.custom("Helvetica", size: 10))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The mock represents the PDF page: always white with fixed ink colors,
        // otherwise dark mode makes black ink and its AA fringe look broken.
        .foregroundStyle(Color(white: 0.15))
        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.tertiary))
        .environment(\.colorScheme, .light)
        .accessibilityLabel("Stamp preview")
    }
}
