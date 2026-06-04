import Foundation
import Security

/// Reads code/document-signing identities from the user's Keychain.
/// The private key stays in the Keychain; we only hold references.
enum KeychainService {
    static func loadIdentities() -> [SigningIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else {
            return []
        }
        return identities.map { SigningIdentity(label: label(for: $0), identity: $0) }
    }

    private static func label(for identity: SecIdentity) -> String {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            return "Unknown certificate"
        }
        var commonName: CFString?
        SecCertificateCopyCommonName(certificate, &commonName)
        if let name = commonName as String? { return name }
        return (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Certificate"
    }
}
