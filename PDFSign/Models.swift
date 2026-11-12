import Foundation
import Security
import AppKit
import PDFKit

/// A signing identity discovered in the Keychain.
struct SigningIdentity: Identifiable, Hashable {
    /// SHA-256 of the certificate (uppercase hex) — stable across launches, so agents
    /// and review requests can pin the exact certificate.
    let id: String
    let label: String
    let identity: SecIdentity
    let details: CertificateDetails

    var fingerprint: String { id }

    static func == (lhs: SigningIdentity, rhs: SigningIdentity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct CertificateDetails: Hashable {
    var subject: String
    var issuer: String?
    var emails: [String]
    var notBefore: Date?
    var notAfter: Date?
    var keyType: String
}

enum FieldKind: String, Codable, CaseIterable, Identifiable {
    case signature, date, text
    var id: String { rawValue }

    var title: String {
        switch self {
        case .signature: return "Signature"
        case .date: return "Date"
        case .text: return "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .signature: return "signature"
        case .date: return "calendar"
        case .text: return "textformat"
        }
    }

    /// Size used when the user clicks instead of dragging (page points).
    var defaultSize: CGSize {
        switch self {
        case .signature: return CGSize(width: 180, height: 60)
        case .date: return CGSize(width: 90, height: 18)
        case .text: return CGSize(width: 160, height: 18)
        }
    }
}

/// A field placed on the document: where it goes (PDF page points, origin bottom-left)
/// and what it shows. Only the first signature field is the cryptographic signature;
/// the rest are stamped into the same signed revision.
struct PlacedField: Identifiable, Equatable {
    let id: UUID
    var kind: FieldKind
    var pageIndex: Int
    var rect: CGRect
    /// .text: the text to stamp
    var text: String = ""
    /// .date: DateFormatter pattern; the date is resolved at signing time
    var dateFormat: String = PlacedField.defaultDateFormat
    /// .signature: fills this existing empty signature field of the document; its
    /// position comes from the form, so the box can't be moved or resized.
    var formFieldName: String? = nil

    init(id: UUID = UUID(), kind: FieldKind, pageIndex: Int, rect: CGRect,
         text: String = "", dateFormat: String = PlacedField.defaultDateFormat,
         formFieldName: String? = nil) {
        self.id = id
        self.kind = kind
        self.pageIndex = pageIndex
        self.rect = rect
        self.text = text
        self.dateFormat = dateFormat
        self.formFieldName = formFieldName
    }

    var isFormField: Bool { formFieldName != nil }

    /// Numeric, locale-ordered date (e.g. 11/03/2026 or 03.11.2026) — ASCII-only so it
    /// renders with the standard PDF fonts.
    static let defaultDateFormat =
        DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: .current) ?? "yyyy-MM-dd"

    /// What the field displays when signed at `date`; nil for signature stamps.
    func displayText(at date: Date = Date()) -> String? {
        switch kind {
        case .signature: return nil
        case .text: return text
        case .date:
            let df = DateFormatter()
            df.dateFormat = dateFormat.isEmpty ? Self.defaultDateFormat : dateFormat
            return df.string(from: date)
        }
    }
}

/// What the visible stamp will contain — mirrors the engine's appearance inputs so the
/// placement box can render a faithful preview of the stamp before signing.
struct StampAppearance: Equatable {
    var image: NSImage? = nil
    var name: String? = nil
    var showDate: Bool = true
    var customText: String? = nil

    static func == (lhs: StampAppearance, rhs: StampAppearance) -> Bool {
        lhs.name == rhs.name
            && lhs.showDate == rhs.showDate
            && lhs.customText == rhs.customText
            && lhs.image === rhs.image
    }
}

/// An empty signature field the document already has — a place it expects to be signed.
struct FormSignatureField: Equatable, Identifiable {
    var name: String
    var pageIndex: Int
    /// unrotated page space, like PlacedField.rect
    var rect: CGRect
    var id: String { name }
}

extension PDFPage {
    /// Page space (unrotated, what PDFKit and the engine use) → the page as displayed:
    /// /Rotate applied, origin at the displayed bottom-left corner of the media box.
    var displayTransform: CGAffineTransform { transform(for: .mediaBox) }

    var displaySize: CGSize {
        let b = bounds(for: .mediaBox)
        return rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    func toDisplay(_ r: CGRect) -> CGRect { r.applying(displayTransform) }
    func fromDisplay(_ r: CGRect) -> CGRect { r.applying(displayTransform.inverted()) }

    /// A direction as seen on screen (e.g. an arrow-key nudge) → the page-space vector.
    func pageVector(fromDisplay v: CGVector) -> CGVector {
        let t = displayTransform
        let lin = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0).inverted()
        let p = CGPoint(x: v.dx, y: v.dy).applying(lin)
        return CGVector(dx: p.x, dy: p.y)
    }

    /// Page-space size of a box that should look `size` on screen.
    func pageSize(fromDisplay size: CGSize) -> CGSize {
        rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// Keep a rect on the page: shift it back inside, shrinking only if it's larger
    /// than the page itself.
    func clamp(_ r: CGRect) -> CGRect {
        let pb = bounds(for: .mediaBox)
        let w = min(r.width, pb.width), h = min(r.height, pb.height)
        return CGRect(x: min(max(r.minX, pb.minX), pb.maxX - w),
                      y: min(max(r.minY, pb.minY), pb.maxY - h), width: w, height: h)
    }
}
