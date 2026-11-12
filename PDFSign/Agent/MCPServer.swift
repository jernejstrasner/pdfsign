import Foundation

/// Minimal Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Hand-rolled to keep the app dependency-free: we only need initialize, ping,
/// tools/list and tools/call. stdout carries protocol messages only.
final class MCPServer {
    private let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(),
                      "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        // Requests carry an id; notifications (e.g. notifications/initialized) get no reply.
        guard let id = message["id"] else { return }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            reply(id, [
                "protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "pdfsign", "version": CLI.appVersion],
                "instructions": Self.instructions,
            ])
        case "ping":
            reply(id, [String: Any]())
        case "tools/list":
            reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            reply(id, call(name, args))
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    // MARK: Tools

    private func call(_ name: String, _ a: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "list_identities":
                return try text(AgentCore.identities())
            case "inspect_pdf":
                return try text(AgentCore.inspect(try string(a, "pdf")))
            case "get_text":
                return try text(AgentCore.text(try string(a, "pdf"), page: a["page"] as? Int))
            case "find_text":
                return try text(AgentCore.find(try string(a, "pdf"), query: try string(a, "query"),
                                               caseSensitive: a["case_sensitive"] as? Bool ?? false))
            case "render_page":
                let result = try AgentCore.render(
                    try string(a, "pdf"), page: a["page"] as? Int ?? 1, fields: try fields(a),
                    scale: (a["scale"] as? NSNumber)?.doubleValue ?? 1.5, guides: a["guides"] as? Bool ?? true,
                    identity: a["identity"] as? String, out: a["out"] as? String)
                let meta = String(data: try CLI.encoder.encode(result), encoding: .utf8) ?? ""
                return ["content": [
                    ["type": "image", "data": result.png.base64EncodedString(), "mimeType": "image/png"],
                    ["type": "text", "text": meta],
                ]]
            case "sign_pdf":
                let stamp = a["stamp"] as? [String: Any] ?? [:]
                var image = AgentCore.StampImageChoice.saved
                switch stamp["image"] as? String {
                case nil, "saved": break
                case "none": image = .none
                case let path?: image = .file(path)
                }
                return try text(AgentCore.sign(
                    try string(a, "pdf"), output: try string(a, "output"), identity: try string(a, "identity"),
                    fields: try fields(a), stampImage: image, stampDate: stamp["date"] as? Bool,
                    stampText: stamp["text"] as? String, reason: a["reason"] as? String,
                    location: a["location"] as? String, overwrite: a["overwrite"] as? Bool ?? false))
            case "open_for_review":
                return try text(AgentCore.review(try string(a, "pdf"), fields: try fields(a),
                                                 identity: a["identity"] as? String,
                                                 output: a["output"] as? String, note: a["note"] as? String))
            default:
                throw AgentError("Unknown tool: \(name)")
            }
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    private func text<T: Encodable>(_ value: T) throws -> [String: Any] {
        ["content": [["type": "text", "text": String(data: try CLI.encoder.encode(value), encoding: .utf8) ?? ""]]]
    }

    private func string(_ a: [String: Any], _ key: String) throws -> String {
        guard let v = a[key] as? String, !v.isEmpty else { throw AgentError("Missing argument \"\(key)\".") }
        return v
    }

    /// Fields arrive as JSON values (or, from some clients, as a JSON string).
    private func fields(_ a: [String: Any]) throws -> [FieldSpec] {
        guard let raw = a["fields"] else { return [] }
        if let s = raw as? String { return try FieldSpec.decodeList(Data(s.utf8)) }
        return try FieldSpec.decodeList(try JSONSerialization.data(withJSONObject: raw))
    }

    // MARK: Transport

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    // MARK: Schema

    static let instructions = """
    PDFSign applies visible, cryptographic (PAdES) signatures to PDFs using a certificate from the \
    user's macOS Keychain; the private key never leaves the Keychain. Coordinates are PDF points on the \
    page AS DISPLAYED (rotation applied, like render_page shows it) with the origin at its BOTTOM-LEFT; \
    pages are 1-based. Workflow: inspect_pdf / find_text / get_text to locate where to sign (labels like \
    "Signature", "Date") — if inspect_pdf lists an unsigned signature field, fill it with \
    {"type": "signature", "field": <name>} instead of placing a box → propose the remaining fields → \
    render_page to check them visually and adjust → list_identities and confirm the certificate \
    with the user → sign_pdf (or open_for_review to let the user sign in the app). Signing is a legally \
    meaningful act on the user's behalf: only sign when the user asked for it and confirmed the document \
    and certificate.
    """

    private static let rectSchema: [String: Any] = [
        "type": "object",
        "description": "PDF points on the page as displayed, origin bottom-left. An [x, y, width, height] array is also accepted.",
        "properties": ["x": ["type": "number"], "y": ["type": "number"],
                       "width": ["type": "number"], "height": ["type": "number"]],
        "required": ["x", "y", "width", "height"],
    ]

    private static let fieldsSchema: [String: Any] = [
        "type": "array",
        "description": "Fields to stamp. One signature field carries the cryptographic signature (the "
            + "existing form field named by \"field\", else the first one); further signature stamps "
            + "show the same signature, and dates and text are stamped into the same signed revision. "
            + "Typical sizes: signature 180×60 pt, date/text 14–20 pt high.",
        "items": [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": ["signature", "date", "text"]],
                "field": ["type": "string",
                          "description": "signature only: name of an unsigned signature field from inspect_pdf to fill "
                              + "in place (then page and rect are taken from the form). At most one per call."],
                "page": ["type": "integer", "minimum": 1, "description": "1-based page number"],
                "rect": rectSchema,
                "text": ["type": "string", "description": "text fields: the text to stamp"],
                "format": ["type": "string",
                           "description": "date fields: date pattern, e.g. yyyy-MM-dd (default: locale's numeric date). The date is the signing date."],
            ],
            "required": ["type"],
        ],
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = [], readOnly: Bool = true) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false],
        ]
    }

    private static let pdfArg: [String: Any] = ["type": "string", "description": "Absolute path to the PDF"]

    static let tools: [[String: Any]] = [
        tool("list_identities",
             "List signing certificates in the user's Keychain: name, SHA-256 fingerprint, issuer, emails, validity.",
             [:]),
        tool("inspect_pdf",
             "Page count, displayed page sizes and rotation, and existing form fields (an unsigned signature field marks where to sign; fill it by name).",
             ["pdf": pdfArg], required: ["pdf"]),
        tool("get_text",
             "Text lines with their rectangles, for one page or the whole document.",
             ["pdf": pdfArg, "page": ["type": "integer", "minimum": 1]], required: ["pdf"]),
        tool("find_text",
             "Find text (e.g. \"Signature\", \"Date:\") and return each match's page, rectangle and surrounding line.",
             ["pdf": pdfArg, "query": ["type": "string"], "case_sensitive": ["type": "boolean"]],
             required: ["pdf", "query"]),
        tool("render_page",
             "Render a page as PNG with the proposed fields drawn in, to verify placement visually. Guides (default on) add a 50 pt grid labelled in PDF points and numbered field outlines.",
             ["pdf": pdfArg, "page": ["type": "integer", "minimum": 1], "fields": fieldsSchema,
              "scale": ["type": "number", "description": "pixels per point, default 1.5"],
              "guides": ["type": "boolean"],
              "identity": ["type": "string", "description": "certificate to preview the stamp name with"],
              "out": ["type": "string", "description": "optional path to also save the PNG"]],
             required: ["pdf"]),
        tool("sign_pdf",
             "Digitally sign the PDF with a Keychain certificate and write a signed copy (the input is never modified). Only call after the user confirmed the document, field placement and certificate. macOS may ask the user to allow Keychain access.",
             ["pdf": pdfArg,
              "output": ["type": "string", "description": "Absolute path for the signed PDF"],
              "identity": ["type": "string",
                           "description": "SHA-256 fingerprint (or unique ≥8-char prefix) or exact certificate name from list_identities"],
              "fields": fieldsSchema,
              "stamp": ["type": "object",
                        "description": "Signature stamp look; defaults to the user's saved settings in the app",
                        "properties": [
                            "image": ["type": "string", "description": "\"saved\" (user's signature image), \"none\" (seal badge), or a path to a PNG"],
                            "date": ["type": "boolean", "description": "show the signing time (UTC) in the stamp"],
                            "text": ["type": "string", "description": "extra line under the signer name"],
                        ]],
              "reason": ["type": "string"], "location": ["type": "string"],
              "overwrite": ["type": "boolean", "description": "replace an existing output file"]],
             required: ["pdf", "output", "identity", "fields"], readOnly: false),
        tool("open_for_review",
             "Open the PDF in the PDFSign app with the fields pre-placed (and optionally the certificate pre-selected) so the user reviews and signs it themselves. Nothing is signed by this call.",
             ["pdf": pdfArg, "fields": fieldsSchema,
              "identity": ["type": "string"], "output": ["type": "string", "description": "suggested save path"],
              "note": ["type": "string", "description": "short message shown to the user above the document"]],
             required: ["pdf"], readOnly: false),
    ]
}
