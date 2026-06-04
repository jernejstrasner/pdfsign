import SwiftUI
import PDFKit
import Security

@Observable
final class AppModel {
    enum Phase: Equatable {
        case empty
        case editing
        case signing
        case done(URL)
        case failed(String)
    }

    var phase: Phase = .empty
    var sourceURL: URL?
    var document: PDFDocument?
    var identities: [SigningIdentity] = []
    var selectedIdentity: SigningIdentity?
    var box: SignatureBox?
    var placing = false

    var canSign: Bool { box != nil && selectedIdentity != nil && sourceURL != nil }

    func loadIdentities() {
        identities = KeychainService.loadIdentities()
        if selectedIdentity == nil || !identities.contains(where: { $0.id == selectedIdentity?.id }) {
            selectedIdentity = identities.first
        }
    }

    /// Copies the picked file into a temp location we own, then loads it.
    func open(pickedURL: URL) {
        let didAccess = pickedURL.startAccessingSecurityScopedResource()
        defer { if didAccess { pickedURL.stopAccessingSecurityScopedResource() } }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(pickedURL.lastPathComponent)
        try? FileManager.default.removeItem(at: temp)
        do {
            try FileManager.default.copyItem(at: pickedURL, to: temp)
        } catch {
            phase = .failed("Could not read that file.")
            return
        }
        guard let doc = PDFDocument(url: temp) else {
            phase = .failed("That file isn't a readable PDF.")
            return
        }
        sourceURL = temp
        document = doc
        box = nil
        placing = true   // draw tool active by default — user can place immediately
        phase = .editing
        loadIdentities()
    }

    func reset() {
        phase = .empty
        sourceURL = nil
        document = nil
        box = nil
        placing = false
    }

    var defaultSaveName: String {
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "document"
        return "\(base)-signed.pdf"
    }

    func sign(to outputURL: URL) {
        guard let source = sourceURL, let identity = selectedIdentity, let box else { return }
        phase = .signing
        let secIdentity = identity.identity
        let signerName = identity.label
        let pageIndex = box.pageIndex
        let rect = box.rect

        Task.detached {
            do {
                try PDFSigningEngine.signPDF(
                    at: source,
                    outputURL: outputURL,
                    pageIndex: pageIndex,
                    rect: rect,
                    identity: secIdentity,
                    signerName: signerName,
                    reason: nil,
                    location: nil)
                await MainActor.run { self.phase = .done(outputURL) }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }
}
