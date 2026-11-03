import CryptoKit
import Foundation
import Security

/// The Mac's long-lived TLS identity: a P-256 key and a self-signed certificate.
/// A phone pins the SHA-256 fingerprint of the certificate when it pairs, so no certificate authority is involved.
/// The identity lives in memory (`SecIdentityCreate`), so the keychain never asks for a password.
struct PeerIdentity {
    let identity: SecIdentity
    let certificateDER: Data
    /// Base64url SHA-256 of the DER certificate, without padding.
    let fingerprint: String

    /// The short ID in Bonjour TXT records and in `GET /v1/info`.
    var deviceID: String { String(fingerprint.prefix(16)) }

    private struct Stored: Codable {
        var privateKey: Data  // X9.63: 04 || X || Y || K
        var certificate: Data
    }

    enum Failure: Error {
        case badKey, badCertificate, noIdentity
    }

    /// Loads the identity from `directory`, or makes and saves a new one.
    static func loadOrCreate(in directory: URL) throws -> PeerIdentity {
        let file = directory.appendingPathComponent("Identity.json")
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let identity = try? make(privateKey: stored.privateKey, certificate: stored.certificate) {
            return identity
        }
        let key = P256.Signing.PrivateKey()
        let certificate = try selfSignedCertificate(for: key, commonName: "Glimpse \(UUID().uuidString.prefix(8))")
        let stored = Stored(privateKey: key.x963Representation, certificate: certificate)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: file, options: .atomic)
        // The file holds a private key: only this user can read it.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return try make(privateKey: stored.privateKey, certificate: stored.certificate)
    }

    static func fingerprint(ofCertificate der: Data) -> String {
        Data(SHA256.hash(data: der)).base64URLEncoded
    }

    private static func make(privateKey: Data, certificate: Data) throws -> PeerIdentity {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let key = SecKeyCreateWithData(privateKey as CFData, attributes as CFDictionary, nil) else { throw Failure.badKey }
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData) else { throw Failure.badCertificate }
        guard let identity = SecIdentityCreate(nil, cert, key) else { throw Failure.noIdentity }
        return PeerIdentity(identity: identity, certificateDER: certificate,
                            fingerprint: fingerprint(ofCertificate: certificate))
    }

    /// A minimal X.509 v3 certificate: ECDSA P-256 with SHA-256, subject = issuer, valid for 20 years.
    private static func selfSignedCertificate(for key: P256.Signing.PrivateKey, commonName: String) throws -> Data {
        let ecdsaWithSHA256 = DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2]))
        let name = DER.sequence(DER.set(DER.sequence(DER.oid([2, 5, 4, 3]), DER.utf8(commonName))))
        let now = Date()
        let validity = DER.sequence(DER.utcTime(now.addingTimeInterval(-86_400)),
                                    DER.utcTime(now.addingTimeInterval(20 * 365 * 86_400)))
        let publicKeyInfo = DER.sequence(
            DER.sequence(DER.oid([1, 2, 840, 10045, 2, 1]), DER.oid([1, 2, 840, 10045, 3, 1, 7])),
            DER.bitString(key.publicKey.x963Representation))
        let tbs = DER.sequence(
            DER.explicit(0, DER.integer(Data([2]))),  // v3
            DER.integer(.random(count: 16)),
            ecdsaWithSHA256,
            name,
            validity,
            name,
            publicKeyInfo)
        let signature = try key.signature(for: tbs).derRepresentation
        return DER.sequence(tbs, ecdsaWithSHA256, DER.bitString(signature))
    }
}

/// Just enough DER to write one certificate.
private enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 {
                bytes.insert(UInt8(length & 0xFF), at: 0)
                length >>= 8
            }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(content)
        return out
    }

    static func sequence(_ parts: Data...) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: Data...) -> Data { tlv(0x31, parts.reduce(Data(), +)) }
    static func explicit(_ number: UInt8, _ content: Data) -> Data { tlv(0xA0 | number, content) }
    static func utf8(_ string: String) -> Data { tlv(0x0C, Data(string.utf8)) }
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }

    /// A positive integer from big-endian bytes.
    static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if value.isEmpty { value = Data([0]) }
        if value.first! & 0x80 != 0 { value.insert(0, at: 0) }
        return tlv(0x02, value)
    }

    static func oid(_ components: [UInt]) -> Data {
        var out = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            var value = component
            var bytes = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            out.append(contentsOf: bytes)
        }
        return tlv(0x06, out)
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(formatter.string(from: date).utf8))
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func random(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
}
