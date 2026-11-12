import SwiftUI
import PDFKit
import Security
import AppKit

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
    var fields: [PlacedField] = []
    var selectedFieldID: UUID?
    /// The document's own empty signature fields — offered as places to sign.
    var formSignatureFields: [FormSignatureField] = []
    /// Field type the placement tool is armed with; nil = normal selection/scrolling.
    var placingKind: FieldKind?
    /// Set by an agent review request: where it suggested saving the signed copy.
    var suggestedOutputURL: URL?
    /// Short note shown above the document (e.g. "Prepared by an agent — review & sign").
    var banner: String?

    // Stamp appearance — persisted across launches (image in Application Support,
    // toggles in UserDefaults). Applied to every signature the engine stamps.
    var signatureImage: NSImage? {
        didSet { SignatureStore.save(signatureImage) }
    }
    var includeDate: Bool {
        didSet { StampSettings.includeDate = includeDate }
    }
    var customText: String {
        didSet { StampSettings.customText = customText }
    }

    private static let dateFormatKey = "field.dateFormat"
    /// Last date format the user chose, so new date fields match the previous ones.
    var lastDateFormat: String {
        didSet { StampSettings.defaults.set(lastDateFormat, forKey: Self.dateFormatKey) }
    }

    init() {
        signatureImage = SignatureStore.load()
        includeDate = StampSettings.includeDate
        customText = StampSettings.customText
        lastDateFormat = StampSettings.defaults.string(forKey: Self.dateFormatKey) ?? PlacedField.defaultDateFormat
    }

    /// Why signing isn't possible yet; empty when ready.
    var signProblems: [String] {
        var out = SigningService.problems(fields: fields, document: document)
        if selectedIdentity == nil { out.append("Choose a signing certificate.") }
        return out
    }

    var canSign: Bool { sourceURL != nil && signProblems.isEmpty }

    /// Current stamp look, fed to the field previews in the PDF view.
    var stampAppearance: StampAppearance {
        let text = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        return StampAppearance(image: signatureImage,
                               name: selectedIdentity?.label,
                               showDate: includeDate,
                               customText: text.isEmpty ? nil : text)
    }

    func loadIdentities() {
        identities = KeychainService.loadIdentities()
        if selectedIdentity == nil || !identities.contains(where: { $0.id == selectedIdentity?.id }) {
            selectedIdentity = identities.first
        }
    }

    /// Copies the picked file into a temp location we own, then loads it.
    @discardableResult
    func open(pickedURL: URL) -> Bool {
        let didAccess = pickedURL.startAccessingSecurityScopedResource()
        defer { if didAccess { pickedURL.stopAccessingSecurityScopedResource() } }

        // Per-open directory: two documents with the same name must not clobber each other.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temp = dir.appendingPathComponent(pickedURL.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: pickedURL, to: temp)
        } catch {
            phase = .failed("Could not read that file.")
            return false
        }
        guard let doc = PDFDocument(url: temp) else {
            phase = .failed("That file isn't a readable PDF.")
            return false
        }
        sourceURL = temp
        document = doc
        fields = []
        selectedFieldID = nil
        suggestedOutputURL = nil
        banner = nil
        formSignatureFields = SigningService.emptySignatureFields(at: temp)
        // Armed by default so the user can place immediately — unless the document already
        // says where to sign; then clicking one of its fields is the first step.
        placingKind = formSignatureFields.isEmpty ? .signature : nil
        phase = .editing
        loadIdentities()
        return true
    }

    /// Load a document prepared by an agent: fields pre-placed, certificate pre-selected,
    /// waiting for a human to review and press Sign.
    func load(review request: ReviewRequest) {
        guard open(pickedURL: URL(fileURLWithPath: request.pdf)) else { return }
        placingKind = nil
        selectedFieldID = nil
        do {
            fields = try AgentCore.resolve(request.fields, in: document!, path: sourceURL!.path)
        } catch {
            fields = []
            banner = "Couldn't place the agent's fields: \(error.localizedDescription)"
            return
        }
        if let query = request.identity {
            if let match = try? KeychainService.resolve(query, in: identities) {
                selectedIdentity = match
            } else {
                selectedIdentity = nil  // force an explicit choice rather than guess
            }
        }
        suggestedOutputURL = request.output.map { URL(fileURLWithPath: $0) }
        banner = request.note ?? "Prepared by an agent — review the fields, then Sign & Save."
    }

    func reset() {
        phase = .empty
        sourceURL = nil
        document = nil
        fields = []
        selectedFieldID = nil
        formSignatureFields = []
        placingKind = nil
        banner = nil
    }

    var defaultSaveName: String {
        if let suggested = suggestedOutputURL { return suggested.lastPathComponent }
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "document"
        return "\(base)-signed.pdf"
    }

    // MARK: Fields

    var selectedField: PlacedField? {
        get { fields.first { $0.id == selectedFieldID } }
        set {
            guard let newValue, let i = fields.firstIndex(where: { $0.id == newValue.id }) else { return }
            fields[i] = newValue
            if newValue.kind == .date { lastDateFormat = newValue.dateFormat }
        }
    }

    func addField(id: UUID, kind: FieldKind, pageIndex: Int, rect: CGRect) {
        let field = PlacedField(id: id, kind: kind, pageIndex: pageIndex, rect: rect,
                                dateFormat: lastDateFormat)
        fields.append(field)
        selectedFieldID = id
    }

    /// Document signature fields not yet chosen for signing.
    var availableSlots: [FormSignatureField] {
        let used = Set(fields.compactMap(\.formFieldName))
        return formSignatureFields.filter { !used.contains($0.name) }
    }

    /// Sign into one of the document's own signature fields. Only one per signature, so
    /// picking another replaces the previous choice.
    func fillSlot(_ name: String) {
        guard let slot = formSignatureFields.first(where: { $0.name == name }) else { return }
        fields.removeAll(where: \.isFormField)
        let field = PlacedField(kind: .signature, pageIndex: slot.pageIndex, rect: slot.rect, formFieldName: name)
        fields.append(field)
        selectedFieldID = field.id
        placingKind = nil
    }

    func moveField(_ id: UUID, to rect: CGRect) {
        guard let i = fields.firstIndex(where: { $0.id == id }), !fields[i].isFormField else { return }
        fields[i].rect = rect
    }

    func deleteField(_ id: UUID) {
        fields.removeAll { $0.id == id }
        if selectedFieldID == id { selectedFieldID = nil }
    }

    /// Same field, nudged down-right so the copy is visibly separate.
    func duplicateSelected() {
        guard var copy = selectedField, let page = document?.page(at: copy.pageIndex) else { return }
        copy = PlacedField(kind: copy.kind, pageIndex: copy.pageIndex,
                           rect: page.clamp(copy.rect.offsetBy(dx: 12, dy: -12)),
                           text: copy.text, dateFormat: copy.dateFormat)
        fields.append(copy)
        selectedFieldID = copy.id
    }

    /// Copy the selected field to the same spot on every other page — initials on each
    /// page, a date in every footer, etc.
    func copySelectedToAllPages() {
        guard let source = selectedField, let document else { return }
        for index in 0..<document.pageCount where index != source.pageIndex {
            guard let page = document.page(at: index) else { continue }
            fields.append(PlacedField(kind: source.kind, pageIndex: index,
                                      rect: page.clamp(source.rect),
                                      text: source.text, dateFormat: source.dateFormat))
        }
    }

    // MARK: Signing

    func sign(to outputURL: URL) {
        guard let source = sourceURL, let identity = selectedIdentity, canSign else { return }
        phase = .signing
        let fields = self.fields
        let options = SigningOptions(identity: identity, signatureImage: signatureImage,
                                     includeDate: includeDate, customText: customText)

        Task.detached {
            do {
                try SigningService.sign(source: source, output: outputURL, fields: fields, options: options)
                await MainActor.run { self.phase = .done(outputURL) }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }
}
