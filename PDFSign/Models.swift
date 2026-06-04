import Foundation
import Security

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
