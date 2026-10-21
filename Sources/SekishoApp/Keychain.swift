import Foundation
import Security

/// The upstream proxy's password lives in the login Keychain, not in the saved rules.
enum Keychain {
    private static let service = "dev.mostlygino.sekisho.upstream-proxy"

    static func upstreamPassword(for user: String) -> String? {
        guard !user.isEmpty, !Demo.on else { return nil }
        var result: AnyObject?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: user, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setUpstreamPassword(_ password: String, for user: String) {
        guard !user.isEmpty, !Demo.on else { return }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: user]
        SecItemDelete(match as CFDictionary)
        guard !password.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// This Mac's addresses on the local network, for setting up a phone.
enum LocalAddresses {
    static func ipv4() -> [(interface: String, address: String)] {
        var out: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { out.append((String(cString: p.pointee.ifa_name), ip)) }
            }
        }
        return out
    }
}
