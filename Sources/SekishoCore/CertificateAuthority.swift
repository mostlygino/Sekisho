import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOSSL
import SwiftASN1
import X509

/// Sekisho's own root CA and the per-host leaf certificates it signs for HTTPS interception.
/// The root key lives in Application Support with mode 0600 and never leaves this Mac.
public final class CertificateAuthority: @unchecked Sendable {
    public let rootCertificate: Certificate
    private let rootKey: P256.Signing.PrivateKey
    /// One key for every leaf, like mitmproxy: signing a new host costs one ECDSA signature, no key generation.
    private let leafKey = P256.Signing.PrivateKey()
    private let contexts = NIOLockedValueBox<[String: NIOSSLContext]>([:])

    /// Where the root lives on disk, for "delete the key" in Settings. Nil for in-memory CAs.
    public private(set) var directory: URL?

    public var rootPEM: String { (try? rootCertificate.serializeAsPEM().pemString) ?? "" }
    public var rootDER: [UInt8] {
        var serializer = DER.Serializer()
        try? serializer.serialize(rootCertificate)
        return serializer.serializedBytes
    }

    /// Loads the root CA from `directory`, creating it on first use.
    public init(directory: URL) throws {
        let keyURL = directory.appendingPathComponent("root-key.pem")
        let certURL = directory.appendingPathComponent("root-cert.pem")
        let fm = FileManager.default
        // Reuse the saved root unless it expires within a month; then make a new one (it must be trusted again).
        if let keyPEM = try? String(contentsOf: keyURL, encoding: .utf8),
           let certPEM = try? String(contentsOf: certURL, encoding: .utf8),
           let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM),
           let cert = try? Certificate(pemEncoded: certPEM),
           cert.notValidAfter > Date().addingTimeInterval(30 * 86_400) {
            rootKey = key
            rootCertificate = cert
            self.directory = directory
            return
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = P256.Signing.PrivateKey()
        let cert = try Self.makeRoot(key: key)
        // Create the key file 0600 before writing the secret into it.
        try? fm.removeItem(at: keyURL)
        guard fm.createFile(atPath: keyURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: keyURL.path])
        }
        let handle = try FileHandle(forWritingTo: keyURL)
        try handle.write(contentsOf: Data(key.pemRepresentation.utf8))
        try handle.close()
        try Data(cert.serializeAsPEM().pemString.utf8).write(to: certURL)
        rootKey = key
        rootCertificate = cert
        self.directory = directory
    }

    /// An in-memory CA for tests.
    public init() throws {
        rootKey = P256.Signing.PrivateKey()
        rootCertificate = try Self.makeRoot(key: rootKey)
    }

    private static func makeRoot(key: P256.Signing.PrivateKey) throws -> Certificate {
        let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac"
        let name = try DistinguishedName {
            CommonName("Sekisho CA (\(host))")
            OrganizationName("Sekisho")
        }
        let publicKey = Certificate.PublicKey(key.publicKey)
        let now = Date()
        return try Certificate(
            version: .v3, serialNumber: .init(), publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-86_400), notValidAfter: now.addingTimeInterval(2 * 365 * 86_400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(digitalSignature: true, keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: publicKey)
            },
            issuerPrivateKey: .init(key))
    }

    /// A leaf for `host` (a DNS name or an IP literal), valid one year: under Apple's 825-day limit for TLS server certs.
    public func leafCertificate(for host: String) throws -> Certificate {
        let san: GeneralName = Self.ipBytes(host).map { .ipAddress(ASN1OctetString(contentBytes: ArraySlice($0))) } ?? .dnsName(host)
        let now = Date()
        let rootPublicKey = rootCertificate.publicKey
        return try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400), notValidAfter: now.addingTimeInterval(365 * 86_400),
            issuer: rootCertificate.subject,
            subject: try DistinguishedName { CommonName(String(host.prefix(64))); OrganizationName("Sekisho") },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([san])
                AuthorityKeyIdentifier(keyIdentifier: SubjectKeyIdentifier(hash: rootPublicKey).keyIdentifier)
            },
            issuerPrivateKey: .init(rootKey))
    }

    public func leafDER(for host: String) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(try leafCertificate(for: host))
        return serializer.serializedBytes
    }

    /// TLS server context presenting a leaf for `host`, cached per host. ALPN is pinned to HTTP/1.1.
    public func serverContext(for host: String) throws -> NIOSSLContext {
        let key = host.lowercased()
        if let cached = contexts.withLockedValue({ $0[key] }) { return cached }
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: try leafDER(for: key), format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)))
        config.applicationProtocols = ["http/1.1"]
        config.minimumTLSVersion = .tlsv12
        let context = try NIOSSLContext(configuration: config)
        // ponytail: the cache starts over past 2,000 hosts instead of evicting the oldest; an LRU if that ever shows.
        contexts.withLockedValue {
            if $0.count >= 2_000 { $0.removeAll() }
            $0[key] = context
        }
        return context
    }

    public static func isIPLiteral(_ host: String) -> Bool { ipBytes(host) != nil }

    static func ipBytes(_ host: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
