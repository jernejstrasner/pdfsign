import Foundation
import Security
import AppKit

/// A signing identity discovered in the Keychain.
struct SigningIdentity: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let identity: SecIdentity

    static func == (lhs: SigningIdentity, rhs: SigningIdentity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Where the visible signature goes: a rectangle in PDF page points (origin bottom-left).
struct SignatureBox: Equatable {
    var pageIndex: Int
    var rect: CGRect
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
            && lhs.image?.tiffRepresentation == rhs.image?.tiffRepresentation
    }
}
