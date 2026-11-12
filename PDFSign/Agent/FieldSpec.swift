import Foundation
import AppKit
import PDFKit

/// Agent-facing field description. Pages are 1-based (as people and viewers count them);
/// rects are PDF points on the page *as displayed* (its /Rotate applied), origin at the
/// displayed bottom-left — what a rendered page image shows.
struct FieldSpec: Codable, Equatable {
    var type: FieldKind
    /// Signatures: fill this existing empty signature field (page/rect come from the form).
    var field: String?
    var page: Int?
    var rect: RectSpec?
    /// text fields: the text to stamp
    var text: String?
    /// date fields: DateFormatter pattern (default: locale's numeric date)
    var format: String?

    init(type: FieldKind, field: String? = nil, page: Int? = nil, rect: RectSpec? = nil,
         text: String? = nil, format: String? = nil) {
        self.type = type
        self.field = field
        self.page = page
        self.rect = rect
        self.text = text
        self.format = format
    }

    /// Resolve against the document: displayed → page-space rect, form field → its widget.
    /// `formFields` is the engine's signature field list (needed only when `field` is set).
    func placedField(in doc: PDFDocument, formFields: [PDFSignatureFieldInfo]) throws -> PlacedField {
        if let name = field {
            guard type == .signature else {
                throw AgentError("\"field\" only applies to signature fields (got \(type.rawValue)).")
            }
            guard let match = formFields.first(where: { $0.name == name }) else {
                let empty = formFields.filter { !$0.isSigned }.map { "\"\($0.name)\"" }
                throw AgentError("No signature field named \"\(name)\". " + (empty.isEmpty
                    ? "The document has no empty signature fields."
                    : "Empty signature fields: \(empty.joined(separator: ", "))."))
            }
            if match.isSigned { throw AgentError("The signature field \"\(name)\" is already signed.") }
            return PlacedField(kind: .signature, pageIndex: match.pageIndex, rect: match.rect,
                               formFieldName: name)
        }
        guard let page, let rect else {
            throw AgentError("A \(type.rawValue) field needs \"page\" and \"rect\"" +
                             (type == .signature ? " (or \"field\": an existing signature field's name)." : "."))
        }
        guard page >= 1, page <= doc.pageCount, let p = doc.page(at: page - 1) else {
            throw AgentError("Page \(page) is out of range (1…\(doc.pageCount)).")
        }
        return PlacedField(kind: type, pageIndex: page - 1, rect: p.fromDisplay(rect.cgRect),
                           text: text ?? "", dateFormat: format ?? PlacedField.defaultDateFormat)
    }

    /// Accepts `{"fields": [...]}` or a bare `[...]`.
    static func decodeList(_ data: Data) throws -> [FieldSpec] {
        let decoder = JSONDecoder()
        do {
            if let wrapped = try? decoder.decode([String: [FieldSpec]].self, from: data),
               let fields = wrapped["fields"] {
                return fields
            }
            return try decoder.decode([FieldSpec].self, from: data)
        } catch let error as DecodingError {
            throw AgentError("Invalid fields JSON: \(error.readable)")
        }
    }
}

/// `{"x":…, "y":…, "width":…, "height":…}` or `[x, y, width, height]` — models produce both.
struct RectSpec: Codable, Equatable {
    var x, y, width, height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    init(_ r: CGRect) {
        self.init(x: Self.round(r.minX), y: Self.round(r.minY),
                  width: Self.round(r.width), height: Self.round(r.height))
    }

    private static func round(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    private enum Keys: String, CodingKey { case x, y, width, height }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            x = try array.decode(Double.self); y = try array.decode(Double.self)
            width = try array.decode(Double.self); height = try array.decode(Double.self)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width); height = try c.decode(Double.self, forKey: .height)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
    }
}

struct AgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension DecodingError {
    var readable: String {
        func path(_ c: [CodingKey]) -> String {
            c.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch self {
        case .keyNotFound(let key, let ctx): return "missing \"\(key.stringValue)\" at \(path(ctx.codingPath))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "\(ctx.debugDescription) at \(path(ctx.codingPath))"
        @unknown default: return localizedDescription
        }
    }
}

// MARK: - Review hand-off

/// A document an agent prepared for a human to review and sign in the GUI.
struct ReviewRequest: Codable {
    var pdf: String
    var fields: [FieldSpec]
    var identity: String?
    var output: String?
    var note: String?
    var created = Date()
}

/// File-drop inbox between the CLI/MCP process and the GUI: the agent side writes a
/// request and pings; the GUI consumes it on launch or on the ping. A file (not launch
/// arguments) because the app may already be running.
enum ReviewInbox {
    static let notification = Notification.Name("com.strsnr.pdfsign.review")

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFSign/inbox", isDirectory: true)
    }

    static func post(_ request: ReviewRequest) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(request).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"),
                                          options: .atomic)
    }

    /// Newest pending request; all pending files are removed (older ones are stale).
    static func consume() -> ReviewRequest? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var newest: ReviewRequest?
        for file in files where file.pathExtension == "json" {
            defer { try? fm.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let request = try? decoder.decode(ReviewRequest.self, from: data) else { continue }
            if newest == nil || request.created > newest!.created { newest = request }
        }
        return newest
    }
}
