import Foundation
import SekishoCore
import Security

/// The macOS web proxy settings, switched with `networksetup` (admin users need no password for it).
enum SystemProxy {
    struct Setting: Codable, Equatable {
        var enabled: Bool
        var server: String
        var port: Int
    }
    struct Snapshot: Codable, Equatable {
        var web: [String: Setting]
        var secure: [String: Setting]
    }

    static let snapshotKey = "systemProxySnapshot"

    /// Enabled network services (networksetup marks disabled ones with `*`).
    static func services() -> [String] {
        run(["-listallnetworkservices"]).split(separator: "\n").dropFirst()
            .map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    static func current() -> Snapshot {
        var snapshot = Snapshot(web: [:], secure: [:])
        for service in services() {
            snapshot.web[service] = parse(run(["-getwebproxy", service]))
            snapshot.secure[service] = parse(run(["-getsecurewebproxy", service]))
        }
        return snapshot
    }

    static func pointsAt(port: Int) -> Bool {
        current().web.values.contains { $0.enabled && $0.server == "127.0.0.1" && $0.port == port }
    }

    /// Points every service in `before` at Sekisho, one by one, so a VPN service that refuses does not sink the rest.
    /// Returns the services that refused. Throws (with everything put back) only when none accepted.
    static func enable(port: Int, before: Snapshot) throws -> [String] {
        var refused: [String] = []
        var messages: [String] = []
        for service in before.web.keys.sorted() {
            do {
                try check(run(["-setwebproxy", service, "127.0.0.1", String(port)]))
                try check(run(["-setsecurewebproxy", service, "127.0.0.1", String(port)]))
            } catch {
                refused.append(service)
                messages.append("\(service): \(error.localizedDescription)")
                if let web = before.web[service] { apply(web, service: service, secure: false) }
                if let secure = before.secure[service] { apply(secure, service: service, secure: true) }
            }
        }
        if refused.count == before.web.count {
            restore(before)
            throw Failure(message: messages.first ?? "No network service accepted the proxy setting.")
        }
        return refused
    }

    static func restore(_ snapshot: Snapshot) {
        for (service, s) in snapshot.web { apply(s, service: service, secure: false) }
        for (service, s) in snapshot.secure { apply(s, service: service, secure: true) }
    }

    private static func apply(_ s: Setting, service: String, secure: Bool) {
        let kind = secure ? "securewebproxy" : "webproxy"
        if s.enabled, !s.server.isEmpty {
            _ = run(["-set\(kind)", service, s.server, String(s.port)])
        } else {
            _ = run(["-set\(kind)state", service, "off"])
        }
    }

    private static func parse(_ text: String) -> Setting {
        var s = Setting(enabled: false, server: "", port: 0)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": s.enabled = parts[1] == "Yes"
            case "Server": s.server = parts[1]
            case "Port": s.port = Int(parts[1]) ?? 0
            default: break
            }
        }
        return s
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func check(_ output: String) throws {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { throw Failure(message: "networksetup: \(text)") }
    }

    @discardableResult
    private static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return error.localizedDescription }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Trust for Sekisho's root CA in the login keychain. macOS asks for the user's password itself.
enum CertificateTrust {
    /// True when a leaf Sekisho signs would pass the system's TLS check, which is what apps will do.
    static func isTrusted(_ ca: CertificateAuthority) -> Bool {
        guard let leafDER = try? ca.leafDER(for: "sekisho.test"),
              let leaf = SecCertificateCreateWithData(nil, Data(leafDER) as CFData),
              let root = SecCertificateCreateWithData(nil, Data(ca.rootDER) as CFData) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, root] as CFArray, SecPolicyCreateSSL(true, "sekisho.test" as CFString), &trust) == errSecSuccess,
              let trust else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    static func install(_ ca: CertificateAuthority) throws {
        guard let cert = SecCertificateCreateWithData(nil, Data(ca.rootDER) as CFData) else { throw failure("The certificate could not be read.") }
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw failure(message(status)) }
        // Trusted for TLS server authentication only, not code signing, mail or anything else.
        let sslOnly: [[String: Any]] = [[kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
                                         kSecTrustSettingsResult as String: SecTrustSettingsResult.trustRoot.rawValue]]
        let trust = SecTrustSettingsSetTrustSettings(cert, .user, sslOnly as CFArray)
        guard trust == errSecSuccess else { throw failure(message(trust)) }
    }

    static func remove(_ ca: CertificateAuthority) throws {
        guard let cert = SecCertificateCreateWithData(nil, Data(ca.rootDER) as CFData) else { return }
        let status = SecTrustSettingsRemoveTrustSettings(cert, .user)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(message(status)) }
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert] as CFDictionary)
        // The key goes too, so an untrusted root can never quietly become trusted again. A new one is made at next launch.
        if let directory = ca.directory {
            for file in ["root-key.pem", "root-cert.pem"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
        }
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Security error \(status)"
    }
    private static func failure(_ text: String) -> SystemProxy.Failure { SystemProxy.Failure(message: text) }
}
