import AppKit
import PDFKit

/// Stamp appearance settings shared by the GUI and the agent interface.
enum StampSettings {
    private static let includeDateKey = "stamp.includeDate"
    private static let customTextKey = "stamp.customText"
    private static let suite = "com.strsnr.pdfsign"

    /// Invoked through a symlink the binary may not resolve its bundle, and
    /// `.standard` would then point at a different domain than the GUI's.
    static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == suite ? .standard : (UserDefaults(suiteName: suite) ?? .standard)
    }

    static var includeDate: Bool {
        get { defaults.object(forKey: includeDateKey) as? Bool ?? true }  // default on
        set { defaults.set(newValue, forKey: includeDateKey) }
    }

    static var customText: String {
        get { defaults.string(forKey: customTextKey) ?? "" }
        set { defaults.set(newValue, forKey: customTextKey) }
    }
}

/// Everything the engine needs besides the document and fields.
struct SigningOptions {
    var identity: SigningIdentity
    var signatureImage: NSImage?
    var includeDate: Bool
    var customText: String
    var reason: String?
    var location: String?

    var stampAppearance: StampAppearance {
        let text = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        return StampAppearance(image: signatureImage, name: identity.label,
                               showDate: includeDate, customText: text.isEmpty ? nil : text)
    }
}

enum SigningService {
    struct ValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Problems that make a field list unsignable, phrased for the user. Empty = OK.
    static func problems(fields: [PlacedField], document: PDFDocument?) -> [String] {
        var out: [String] = []
        if !fields.contains(where: { $0.kind == .signature }) {
            out.append("Add at least one signature field.")
        }
        // Each of the document's signature fields is its own signature, often another signer's.
        if fields.filter(\.isFormField).count > 1 {
            out.append("Only one of the document's signature fields can be signed at a time.")
        }
        for (i, f) in fields.enumerated() {
            let name = "Field \(i + 1) (\(f.kind.rawValue), page \(f.pageIndex + 1))"
            if f.isFormField, f.kind != .signature {
                out.append("\(name) targets a form field but isn't a signature.")
            }
            if f.kind == .text, f.text.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("\(name) has no text.")
            }
            if f.rect.width < 4 || f.rect.height < 4 {
                out.append("\(name) is too small (min 4×4 pt).")
            }
            if let document {
                if f.pageIndex < 0 || f.pageIndex >= document.pageCount {
                    out.append("\(name): the document has \(document.pageCount) page(s).")
                } else if let page = document.page(at: f.pageIndex),
                          !page.bounds(for: .mediaBox).intersects(f.rect) {
                    out.append("\(name) lies outside the page.")
                }
            }
        }
        return out
    }

    /// Signs synchronously; call off the main thread in the GUI (the Keychain may prompt).
    static func sign(source: URL, output: URL, fields: [PlacedField], options: SigningOptions,
                     at date: Date = Date()) throws {
        let issues = problems(fields: fields, document: PDFDocument(url: source))
        if !issues.isEmpty { throw ValidationError(message: issues.joined(separator: " ")) }

        let engineFields = fields.map { f in
            PDFSignField(kind: f.kind == .signature ? .signature : .text,
                         pageIndex: f.pageIndex, rect: f.rect, text: f.displayText(at: date),
                         formFieldName: f.formFieldName)
        }
        let text = options.customText.trimmingCharacters(in: .whitespacesAndNewlines)
        try PDFSigningEngine.signPDF(
            at: source,
            outputURL: output,
            fields: engineFields,
            identity: options.identity.identity,
            signerName: options.identity.label,
            reason: options.reason,
            location: options.location,
            signatureImagePNG: options.signatureImage.flatMap { SignatureStore.pngData($0) },
            includeDate: options.includeDate,
            customText: text.isEmpty ? nil : text)
    }

    /// Every signature field of the document (signed or not), via the engine's lookup —
    /// the same one signing uses, so an unsigned one listed here can be filled by name.
    static func signatureFields(at url: URL) throws -> [PDFSignatureFieldInfo] {
        try PDFSigningEngine.signatureFieldsInPDF(at: url)
    }

    /// The document's empty signature fields, for the GUI to offer as places to sign.
    static func emptySignatureFields(at url: URL) -> [FormSignatureField] {
        ((try? signatureFields(at: url)) ?? []).filter { !$0.isSigned }.map {
            FormSignatureField(name: $0.name, pageIndex: $0.pageIndex, rect: $0.rect)
        }
    }
}
