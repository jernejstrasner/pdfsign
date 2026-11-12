import Foundation

/// Headless command-line interface, compiled into the app binary:
///   /Applications/PDFSign.app/Contents/MacOS/PDFSign <command> …
/// Output is JSON on stdout (agents parse it); exit status 0 on success, 1 on error.
enum CLI {
    static let commands: Set<String> = ["identities", "inspect", "text", "find", "render", "sign",
                                        "review", "mcp", "help", "--help", "-h", "version", "--version"]

    /// Returns an exit code when the arguments ask for CLI mode, nil to start the GUI.
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.count > 1, commands.contains(arguments[1]) else { return nil }
        var args = Array(arguments.dropFirst(2))
        let command = arguments[1]
        do {
            switch command {
            case "help", "--help", "-h":
                print(usage)
            case "version", "--version":
                emit(["version": appVersion])
            case "mcp":
                MCPServer().run()
            case "identities":
                emit(AgentCore.identities())
            case "inspect":
                emit(try AgentCore.inspect(try positional(&args, "pdf")))
            case "text":
                let page = try option(&args, "--page").map(int)
                emit(try AgentCore.text(try positional(&args, "pdf"), page: page))
            case "find":
                let caseSensitive = flag(&args, "--case-sensitive")
                let pdf = try positional(&args, "pdf")
                emit(try AgentCore.find(pdf, query: try positional(&args, "query"), caseSensitive: caseSensitive))
            case "render":
                let page = try option(&args, "--page").map(int) ?? 1
                let scale = try option(&args, "--scale").map(double) ?? 1.5
                let guides = !flag(&args, "--no-guides")
                let fields = try option(&args, "--fields").map(readFields) ?? []
                let identity = try option(&args, "--identity")
                let outOption = try option(&args, "--out")
                let pdf = try positional(&args, "pdf")
                let out = outOption
                    ?? URL(fileURLWithPath: pdf).deletingPathExtension().lastPathComponent + "-p\(page).png"
                emit(try AgentCore.render(pdf, page: page, fields: fields, scale: scale, guides: guides,
                                          identity: identity, out: out))
            case "sign":
                let out = try require(option(&args, "--out"), "--out")
                let identity = try require(option(&args, "--identity"), "--identity")
                let fields = try readFields(try require(option(&args, "--fields"), "--fields"))
                var image = AgentCore.StampImageChoice.saved
                if flag(&args, "--no-stamp-image") { image = .none }
                if let path = try option(&args, "--stamp-image") { image = .file(path) }
                var date: Bool?
                if flag(&args, "--stamp-date") { date = true }
                if flag(&args, "--no-stamp-date") { date = false }
                let text = try option(&args, "--stamp-text")
                let reason = try option(&args, "--reason")
                let location = try option(&args, "--location")
                let overwrite = flag(&args, "--overwrite")
                emit(try AgentCore.sign(try positional(&args, "pdf"), output: out, identity: identity,
                                        fields: fields, stampImage: image, stampDate: date, stampText: text,
                                        reason: reason, location: location, overwrite: overwrite))
            case "review":
                let fields = try option(&args, "--fields").map(readFields) ?? []
                let identity = try option(&args, "--identity")
                let out = try option(&args, "--out")
                let note = try option(&args, "--note")
                emit(try AgentCore.review(try positional(&args, "pdf"), fields: fields, identity: identity,
                                          output: out, note: note))
            default:
                return nil
            }
            if let extra = args.first { throw AgentError("Unexpected argument: \(extra)") }
            return 0
        } catch {
            emit(["error": error.localizedDescription])
            return 1
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Argument helpers

    private static func flag(_ args: inout [String], _ name: String) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }

    private static func option(_ args: inout [String], _ name: String) throws -> String? {
        guard let i = args.firstIndex(of: name) else { return nil }
        guard i + 1 < args.count else { throw AgentError("\(name) needs a value.") }
        let value = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return value
    }

    /// First argument that isn't an option. Options are consumed before positionals.
    private static func positional(_ args: inout [String], _ name: String) throws -> String {
        guard let i = args.firstIndex(where: { !$0.hasPrefix("--") }) else { throw AgentError("Missing <\(name)>.") }
        return args.remove(at: i)
    }

    private static func require(_ value: String?, _ name: String) throws -> String {
        guard let value else { throw AgentError("\(name) is required.") }
        return value
    }

    private static func int(_ s: String) throws -> Int {
        guard let v = Int(s) else { throw AgentError("Expected an integer, got \"\(s)\".") }
        return v
    }

    private static func double(_ s: String) throws -> Double {
        guard let v = Double(s) else { throw AgentError("Expected a number, got \"\(s)\".") }
        return v
    }

    /// A path to a JSON file, "-" for stdin, or inline JSON.
    static func readFields(_ source: String) throws -> [FieldSpec] {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        let data: Data
        if trimmed == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            data = Data(trimmed.utf8)
        } else {
            let path = (trimmed as NSString).expandingTildeInPath
            guard let d = FileManager.default.contents(atPath: path) else {
                throw AgentError("Can't read fields file \(path).")
            }
            data = d
        }
        return try FieldSpec.decodeList(data)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static func emit<T: Encodable>(_ value: T) {
        if let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) { print(s) }
    }

    static let usage = """
    PDFSign \(appVersion) — sign PDFs with a Keychain certificate, from the command line or an agent.

    USAGE
      PDFSign <command> [options]        (JSON on stdout; exit 1 + {"error": …} on failure)

    COMMANDS
      identities                         List signing certificates (name, SHA-256 fingerprint, issuer, expiry).
      inspect <pdf>                      Page count, page sizes/rotation, existing form fields (an unsigned
                                         signature field is where to sign — fill it by name, see FIELDS).
      text <pdf> [--page N]              Text lines with their rectangles.
      find <pdf> <query> [--case-sensitive]
                                         Locate text (e.g. "Signature", "Date:") → page + rectangle.
      render <pdf> [--page N] [--fields F] [--out file.png] [--scale 1.5] [--no-guides] [--identity ID]
                                         PNG of a page with the proposed fields drawn in. Guides (default on)
                                         add a 50 pt grid labelled in PDF points and numbered field outlines.
      sign <pdf> --out <path> --identity <ID> --fields F [--overwrite]
           [--stamp-image <png> | --no-stamp-image] [--stamp-date | --no-stamp-date]
           [--stamp-text TEXT] [--reason R] [--location L]
                                         Sign. The input is never modified. Stamp options default to the
                                         app's saved Stamp settings (signature image, date, text).
      review <pdf> [--fields F] [--identity ID] [--out <path>] [--note TEXT]
                                         Open the document in the PDFSign app with the fields pre-placed for
                                         the user to review and sign themselves. Nothing is signed.
      mcp                                Run as an MCP server over stdio (same operations as tools).
      version | help

    IDENTITY (ID)
      A SHA-256 certificate fingerprint (or a unique prefix of ≥ 8 hex chars) from `identities`, or the
      exact certificate name. No fuzzy matching.

    FIELDS (F)
      A JSON file, "-" for stdin, or inline JSON: {"fields": [...]} or a bare array.
        {"type": "signature", "page": 1, "rect": {"x": 350, "y": 90, "width": 180, "height": 60}}
        {"type": "signature", "field": "ClientSignature"}     fill an existing empty signature field
        {"type": "date",      "page": 1, "rect": [350, 60, 90, 18], "format": "yyyy-MM-dd"}
        {"type": "text",      "page": 1, "rect": [72, 60, 160, 18], "text": "Ljubljana"}
      Coordinates are PDF points (1/72 in) on the page AS DISPLAYED (its rotation applied, as `render`
      shows it), origin at the BOTTOM-LEFT; pages are 1-based. One signature field carries the
      cryptographic signature (the named form field, else the first); further signature stamps show the
      same signature, and dates and text are stamped into the same signed revision (one signature covers
      everything). At most one existing form field per signing. Date fields show the signing date in
      `format` (default: locale's numeric date). Typical sizes: signature 180×60, date/text height 14–20.

    WORKFLOW
      1. inspect / find / text  → understand the layout, find empty signature fields or "Signature"/"Date" labels
      2. render --fields F      → look at the PNG, adjust rects until they sit right
      3. identities             → confirm the certificate with the user
      4. sign … (or review … to let the user sign in the app)
    """
}
