import AppKit

/// Persists the user's signature image (drawn or imported) as a PNG in
/// Application Support so it survives across documents and launches —
/// same idea as Preview.app's stored signatures, but our own store.
enum SignatureStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFSign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signature.png")
    }

    static func load() -> NSImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return NSImage(data: data)
    }

    static func save(_ image: NSImage?) {
        let url = fileURL
        if let image, let png = pngData(image) {
            try? png.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Re-encodes any NSImage as PNG (keeps alpha for drawn signatures).
    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
