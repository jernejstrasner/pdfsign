import Foundation
import Security
import CryptoKit

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
        var seen = Set<String>()
        return identities.compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else { return nil }
            let der = SecCertificateCopyData(certificate) as Data
            let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
            // The same cert can surface from several keychains; one entry is enough.
            guard seen.insert(fingerprint).inserted else { return nil }
            return SigningIdentity(id: fingerprint, label: label(for: certificate),
                                   identity: identity, details: details(for: certificate, identity: identity))
        }
    }

    enum ResolveError: LocalizedError {
        case noMatch(String, [SigningIdentity])
        case ambiguous(String, [SigningIdentity])

        var errorDescription: String? {
            switch self {
            case .noMatch(let q, let all):
                return "No signing identity matches \"\(q)\". Available: "
                    + (all.isEmpty ? "none" : all.map { "\($0.label) [\($0.fingerprint.prefix(16))…]" }
                        .joined(separator: ", "))
            case .ambiguous(let q, let matches):
                return "\"\(q)\" matches several identities — pass a fingerprint instead: "
                    + matches.map { "\($0.label) [\($0.fingerprint.prefix(16))…]" }.joined(separator: ", ")
            }
        }
    }

    /// Exact identity selection: a SHA-256 fingerprint (or a unique prefix of ≥ 8 hex
    /// chars, colons/spaces ignored), or an exact, unique common name. No fuzzy matching —
    /// signing with the wrong certificate is not a recoverable mistake.
    static func resolve(_ query: String, in identities: [SigningIdentity]) throws -> SigningIdentity {
        let hex = query.uppercased().filter { !":- ".contains($0) }
        if hex.count >= 8, hex.allSatisfy(\.isHexDigit) {
            let matches = identities.filter { $0.fingerprint.hasPrefix(hex) }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw ResolveError.ambiguous(query, matches) }
        }
        let byName = identities.filter { $0.label == query }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw ResolveError.ambiguous(query, byName) }
        throw ResolveError.noMatch(query, identities)
    }

    private static func label(for certificate: SecCertificate) -> String {
        var commonName: CFString?
        SecCertificateCopyCommonName(certificate, &commonName)
        if let name = commonName as String? { return name }
        return (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Certificate"
    }

    private static func details(for certificate: SecCertificate, identity: SecIdentity) -> CertificateDetails {
        var emails: CFArray?
        SecCertificateCopyEmailAddresses(certificate, &emails)

        let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter]
        let values = SecCertificateCopyValues(certificate, keys as CFArray, nil) as? [String: [String: Any]] ?? [:]
        func date(_ oid: CFString) -> Date? {
            (values[oid as String]?[kSecPropertyKeyValue as String] as? NSNumber)
                .map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        // Issuer is a list of RDN entries; the CN is the human-readable part.
        var issuer: String?
        if let rdns = values[kSecOIDX509V1IssuerName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] {
            issuer = rdns.first { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDCommonName as String) }?[
                kSecPropertyKeyValue as String] as? String
        }

        var keyType = "unknown"
        var key: SecKey?
        if SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
           let attrs = SecKeyCopyAttributes(key) as? [String: Any] {
            let type = attrs[kSecAttrKeyType as String] as? String
            let bits = attrs[kSecAttrKeySizeInBits as String] as? Int
            let name = type == (kSecAttrKeyTypeECSECPrimeRandom as String) ? "EC"
                : type == (kSecAttrKeyTypeRSA as String) ? "RSA" : "other"
            keyType = bits.map { "\(name) \($0)" } ?? name
        }

        return CertificateDetails(
            subject: (SecCertificateCopySubjectSummary(certificate) as String?) ?? label(for: certificate),
            issuer: issuer,
            emails: (emails as? [String]) ?? [],
            notBefore: date(kSecOIDX509V1ValidityNotBefore),
            notAfter: date(kSecOIDX509V1ValidityNotAfter),
            keyType: keyType)
    }
}
