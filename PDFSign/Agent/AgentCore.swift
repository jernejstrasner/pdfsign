import AppKit
import PDFKit
import CryptoKit

/// Headless operations behind the CLI and the MCP server. Stateless: every call carries
/// the document and fields, so an agent can iterate (inspect → place → render → sign)
/// without session bookkeeping. Coordinates: PDF points on the page as displayed (/Rotate
/// applied), origin bottom-left, pages 1-based — converted to/from PDFKit's unrotated page
/// space only at this boundary.
enum AgentCore {

    // MARK: Results

    struct IdentityInfo: Encodable {
        var name: String
        var fingerprint: String
        var subject: String
        var issuer: String?
        var emails: [String]
        var notBefore: Date?
        var notAfter: Date?
        var expired: Bool
        var keyType: String
    }

    struct PageInfo: Encodable {
        var page: Int
        /// as displayed (width/height swap on 90°/270° pages)
        var width: Double
        var height: Double
        var rotation: Int
    }

    struct FormFieldInfo: Encodable {
        var name: String?
        var type: String
        var page: Int
        var rect: RectSpec
        var value: String?
        /// signature fields: whether it's already signed (unsigned ones can be filled by name)
        var signed: Bool?
    }

    struct DocumentInfo: Encodable {
        var path: String
        var pageCount: Int
        var encrypted: Bool
        var pages: [PageInfo]
        /// Existing form widgets. An unsigned signature field is where the document expects
        /// the signature: fill it with {"type": "signature", "field": name}.
        var formFields: [FormFieldInfo]
        var note: String
    }

    struct TextLine: Encodable {
        var page: Int
        var text: String
        var rect: RectSpec
    }

    struct TextMatch: Encodable {
        var page: Int
        var text: String
        var rect: RectSpec
        /// The whole line the match sits on, for disambiguation.
        var line: String
        var lineRect: RectSpec
    }

    struct RenderResult: Encodable {
        var path: String?
        var page: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var scale: Double
        var pageWidth: Double
        var pageHeight: Double
        var note: String
        @SkipEncode var png: Data
    }

    struct SignResult: Encodable {
        var output: String
        var signer: String
        var fingerprint: String
        var fieldCount: Int
        var signatureField: FieldSpec
        var bytes: Int
        var sha256: String
    }

    struct ReviewResult: Encodable {
        var queued: Bool
        var app: String
        var note: String
    }

    // MARK: Operations

    static func identities() -> [IdentityInfo] {
        KeychainService.loadIdentities().map { id in
            IdentityInfo(name: id.label, fingerprint: id.fingerprint, subject: id.details.subject,
                         issuer: id.details.issuer, emails: id.details.emails,
                         notBefore: id.details.notBefore, notAfter: id.details.notAfter,
                         expired: id.details.notAfter.map { $0 < Date() } ?? false,
                         keyType: id.details.keyType)
        }
    }

    static func open(_ path: String) throws -> PDFDocument {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AgentError("No such file: \(url.path)") }
        guard let doc = PDFDocument(url: url) else { throw AgentError("Not a readable PDF: \(url.path)") }
        if doc.isLocked { throw AgentError("The PDF is password-protected; unlock it first.") }
        return doc
    }

    static func inspect(_ path: String) throws -> DocumentInfo {
        let doc = try open(path)
        let signed = Dictionary(
            ((try? SigningService.signatureFields(at: fileURL(path))) ?? []).map { ($0.name, $0.isSigned) },
            uniquingKeysWith: { a, b in a || b })
        var pages: [PageInfo] = []
        var formFields: [FormFieldInfo] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let size = page.displaySize
            pages.append(PageInfo(page: i + 1, width: Double(size.width), height: Double(size.height),
                                  rotation: page.rotation))
            for a in page.annotations where a.type == "Widget" {
                let type: String
                switch a.widgetFieldType {
                case .signature: type = "signature"
                case .text: type = "text"
                case .button: type = "button"
                case .choice: type = "choice"
                default: type = "other"
                }
                formFields.append(FormFieldInfo(name: a.fieldName, type: type, page: i + 1,
                                                rect: RectSpec(page.toDisplay(a.bounds)),
                                                value: a.widgetStringValue.flatMap { $0.isEmpty ? nil : $0 },
                                                signed: type == "signature" ? a.fieldName.flatMap { signed[$0] } : nil))
            }
        }
        return DocumentInfo(
            path: doc.documentURL?.path ?? path, pageCount: doc.pageCount, encrypted: doc.isEncrypted,
            pages: pages, formFields: formFields,
            note: "Coordinates are PDF points on the page as displayed (rotation applied), origin at its "
                + "bottom-left; pages are 1-based. Sign an unsigned signature field with "
                + "{\"type\": \"signature\", \"field\": <name>}.")
    }

    static func text(_ path: String, page: Int?) throws -> [TextLine] {
        let doc = try open(path)
        let indices = try page.map { [try pageIndex($0, in: doc)] } ?? Array(0..<doc.pageCount)
        var out: [TextLine] = []
        for i in indices {
            guard let p = doc.page(at: i),
                  let all = p.selection(for: p.bounds(for: .mediaBox)) else { continue }
            for line in all.selectionsByLine() {
                let s = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { continue }
                out.append(TextLine(page: i + 1, text: s, rect: RectSpec(p.toDisplay(line.bounds(for: p)))))
            }
        }
        return out
    }

    static func find(_ path: String, query: String, caseSensitive: Bool) throws -> [TextMatch] {
        let doc = try open(path)
        guard !query.isEmpty else { throw AgentError("Empty search query.") }
        let selections = doc.findString(query, withOptions: caseSensitive ? [] : [.caseInsensitive])
        return selections.compactMap { sel in
            guard let page = sel.pages.first else { return nil }
            let line = sel.copy() as! PDFSelection
            line.extendForLineBoundaries()
            return TextMatch(page: doc.index(for: page) + 1, text: sel.string ?? query,
                             rect: RectSpec(page.toDisplay(sel.bounds(for: page))),
                             line: (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                             lineRect: RectSpec(page.toDisplay(line.bounds(for: page))))
        }
    }

    /// Render a page (with proposed fields drawn in) for visual verification. Guides add a
    /// labelled 50 pt grid and numbered field outlines so a vision model can read positions.
    static func render(_ path: String, page: Int, fields: [FieldSpec], scale: Double, guides: Bool,
                       identity: String?, out: String?) throws -> RenderResult {
        let doc = try open(path)
        let index = try pageIndex(page, in: doc)
        guard let p = doc.page(at: index) else { throw AgentError("Page \(page) can't be read.") }
        let scale = min(max(scale, 0.25), 4)
        let size = p.displaySize
        let pxW = Int((size.width * scale).rounded()), pxH = Int((size.height * scale).rounded())

        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentError("Could not allocate a \(pxW)×\(pxH) bitmap.")
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.scaleBy(x: scale, y: scale)

        ctx.saveGState()
        p.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        // Fields are drawn from page space exactly like the GUI preview does.
        let appearance = try stampAppearance(identity: identity)
        let placed = try resolve(fields, in: doc, path: path)
        ctx.saveGState()
        ctx.concatenate(p.displayTransform)
        for field in placed where field.pageIndex == index {
            FieldRenderer.withFieldContext(ctx, rect: field.rect, display: p.displayTransform) { size in
                FieldRenderer.draw(field, appearance: appearance, size: size)
            }
        }
        ctx.restoreGState()
        // Guides speak the agent's coordinates: the page as displayed.
        if guides {
            drawGuides(ctx, box: CGRect(origin: .zero, size: size),
                       fields: placed.map { f in var d = f; d.rect = p.toDisplay(f.rect); return d },
                       pageIndex: index)
        }

        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw AgentError("Could not encode the PNG.")
        }
        var written: String?
        if let out {
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            try png.write(to: url, options: .atomic)
            written = url.path
        }
        return RenderResult(
            path: written, page: page, pixelWidth: pxW, pixelHeight: pxH, scale: scale,
            pageWidth: Double(size.width), pageHeight: Double(size.height),
            note: guides ? "Grid lines every 50 pt (labels in PDF points of the page as shown, origin bottom-left). "
                + "Fields are outlined and numbered in list order (#1 = first)." : "Final appearance, no guides.",
            png: png)
    }

    static func sign(_ path: String, output: String, identity query: String, fields specs: [FieldSpec],
                     stampImage: StampImageChoice, stampDate: Bool?, stampText: String?,
                     reason: String?, location: String?, overwrite: Bool) throws -> SignResult {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let dest = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
        let doc = try open(source.path)
        if source.resolvingSymlinksInPath() == dest.resolvingSymlinksInPath() {
            throw AgentError("Output must differ from the input — the original stays untouched.")
        }
        if FileManager.default.fileExists(atPath: dest.path), !overwrite {
            throw AgentError("\(dest.path) already exists; pass overwrite to replace it.")
        }
        if specs.isEmpty { throw AgentError("No fields given; at least one signature field is required.") }

        let identity = try KeychainService.resolve(query, in: KeychainService.loadIdentities())
        if let until = identity.details.notAfter, until < Date() {
            throw AgentError("The certificate \"\(identity.label)\" expired on \(until.formatted()).")
        }
        let fields = try resolve(specs, in: doc, path: source.path)
        let problems = SigningService.problems(fields: fields, document: doc)
        if !problems.isEmpty { throw AgentError(problems.joined(separator: " ")) }

        let options = SigningOptions(identity: identity, signatureImage: try stampImage.load(),
                                     includeDate: stampDate ?? StampSettings.includeDate,
                                     customText: stampText ?? StampSettings.customText,
                                     reason: reason, location: location)
        try SigningService.sign(source: source, output: dest, fields: fields, options: options)

        let data = try Data(contentsOf: dest)
        return SignResult(output: dest.path, signer: identity.label, fingerprint: identity.fingerprint,
                          fieldCount: fields.count,
                          signatureField: specs.first { $0.field != nil } ?? specs.first { $0.type == .signature }!,
                          bytes: data.count,
                          sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// Hand the prepared document to the GUI so a human reviews, picks/confirms the
    /// certificate and signs.
    static func review(_ path: String, fields: [FieldSpec], identity: String?, output: String?,
                       note: String?) throws -> ReviewResult {
        let doc = try open(path)
        let problems = SigningService.problems(fields: try resolve(fields, in: doc, path: path), document: doc)
            .filter { !$0.hasPrefix("Add at least one") }  // the human may still add the signature
        if !problems.isEmpty { throw AgentError(problems.joined(separator: " ")) }

        let abs = { (p: String) in URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.path }
        try ReviewInbox.post(ReviewRequest(pdf: abs(path), fields: fields, identity: identity,
                                           output: output.map(abs), note: note))
        let app = try launchApp()
        return ReviewResult(queued: true, app: app.path,
                            note: "Opened in PDFSign for the user to review and sign. Nothing has been signed yet.")
    }

    // MARK: Helpers

    /// Agent field specs → page-space fields; looks up form fields only when one is named.
    static func resolve(_ specs: [FieldSpec], in doc: PDFDocument, path: String) throws -> [PlacedField] {
        let formFields = specs.contains { $0.field != nil }
            ? try SigningService.signatureFields(at: fileURL(path)) : []
        return try specs.map { try $0.placedField(in: doc, formFields: formFields) }
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    enum StampImageChoice {
        case saved          // the user's signature image from the app (if any)
        case none           // seal badge
        case file(String)

        func load() throws -> NSImage? {
            switch self {
            case .saved: return SignatureStore.load()
            case .none: return nil
            case .file(let path):
                guard let image = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath) else {
                    throw AgentError("Can't read stamp image \(path).")
                }
                return image
            }
        }
    }

    static func stampAppearance(identity query: String?) throws -> StampAppearance {
        let name = try query.map { try KeychainService.resolve($0, in: KeychainService.loadIdentities()).label }
        let text = StampSettings.customText.trimmingCharacters(in: .whitespacesAndNewlines)
        return StampAppearance(image: SignatureStore.load(), name: name ?? "Your Name",
                               showDate: StampSettings.includeDate, customText: text.isEmpty ? nil : text)
    }

    private static func pageIndex(_ page: Int, in doc: PDFDocument) throws -> Int {
        guard page >= 1, page <= doc.pageCount else {
            throw AgentError("Page \(page) is out of range (1…\(doc.pageCount)).")
        }
        return page - 1
    }

    private static func drawGuides(_ ctx: CGContext, box: CGRect, fields: [PlacedField], pageIndex: Int) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let label: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 6, weight: .medium),
            .foregroundColor: NSColor(red: 0.1, green: 0.35, blue: 0.85, alpha: 0.9),
        ]
        var x = (box.minX / 50).rounded(.up) * 50
        while x <= box.maxX {
            let major = Int(x) % 100 == 0
            ctx.setStrokeColor(NSColor(red: 0.2, green: 0.45, blue: 0.95, alpha: major ? 0.35 : 0.15).cgColor)
            ctx.setLineWidth(major ? 0.5 : 0.3)
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: box.minY), CGPoint(x: x, y: box.maxY)])
            if major {
                ("\(Int(x))" as NSString).draw(at: CGPoint(x: x + 1, y: box.minY + 1), withAttributes: label)
                ("\(Int(x))" as NSString).draw(at: CGPoint(x: x + 1, y: box.maxY - 8), withAttributes: label)
            }
            x += 50
        }
        var y = (box.minY / 50).rounded(.up) * 50
        while y <= box.maxY {
            let major = Int(y) % 100 == 0
            ctx.setStrokeColor(NSColor(red: 0.2, green: 0.45, blue: 0.95, alpha: major ? 0.35 : 0.15).cgColor)
            ctx.setLineWidth(major ? 0.5 : 0.3)
            ctx.strokeLineSegments(between: [CGPoint(x: box.minX, y: y), CGPoint(x: box.maxX, y: y)])
            if major {
                ("\(Int(y))" as NSString).draw(at: CGPoint(x: box.minX + 1, y: y + 1), withAttributes: label)
                ("\(Int(y))" as NSString).draw(at: CGPoint(x: box.maxX - 16, y: y + 1), withAttributes: label)
            }
            y += 50
        }

        let tag: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold), .foregroundColor: NSColor.white,
        ]
        for (i, f) in fields.enumerated() where f.pageIndex == pageIndex {
            let color = f.kind == .signature ? NSColor.systemRed : NSColor.systemOrange
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(0.8)
            ctx.stroke(f.rect)
            let text = "#\(i + 1) \(f.kind.rawValue)\(f.formFieldName.map { " \"\($0)\"" } ?? "")" as NSString
            let size = text.size(withAttributes: tag)
            let bg = CGRect(x: f.rect.minX, y: f.rect.maxY, width: size.width + 4, height: size.height)
            ctx.setFillColor(color.cgColor)
            ctx.fill(bg)
            text.draw(at: CGPoint(x: bg.minX + 2, y: bg.minY), withAttributes: tag)
        }
    }

    /// Bring up the GUI: ping a running instance (it picks the request from the inbox), or
    /// launch one, which reads the inbox at startup.
    private static func launchApp() throws -> URL {
        var appURL = Bundle.main.bundleURL
        if appURL.pathExtension != "app" {
            guard let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.strsnr.pdfsign") else {
                throw AgentError("Can't locate PDFSign.app to open the review.")
            }
            appURL = installed
        }

        let me = ProcessInfo.processInfo.processIdentifier
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.strsnr.pdfsign")
            .first(where: { $0.processIdentifier != me && $0.activationPolicy == .regular }) {
            DistributedNotificationCenter.default().postNotificationName(
                ReviewInbox.notification, object: nil, userInfo: nil, deliverImmediately: true)
            running.activate()
            return running.bundleURL ?? appURL
        }

        // This CLI process is the app's own executable, so LaunchServices counts it as a
        // running "PDFSign" and routes a plain open (or NSWorkspace.openApplication) to it,
        // failing with -600. `open -n` forces a real GUI instance.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", appURL.path]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            throw AgentError("Couldn't open PDFSign: \(error.localizedDescription)")
        }
        if open.terminationStatus != 0 {
            throw AgentError("Couldn't open PDFSign (open exited \(open.terminationStatus)).")
        }
        return appURL
    }
}

/// Keeps bulky payloads (PNG bytes) out of the JSON a CLI prints.
@propertyWrapper
struct SkipEncode<Value>: Encodable {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    func encode(to encoder: Encoder) throws {}
}

extension KeyedEncodingContainer {
    mutating func encode<T>(_ value: SkipEncode<T>, forKey key: Key) throws {}
}
