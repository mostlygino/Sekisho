import Darwin
import Foundation

/// What Sekisho did to an exchange. Recorded traffic carries none of these; the UI gives each its lever colour.
public enum Intervention: String, Codable, Sendable, Hashable {
    case hold, mapLocal, mapRemote, block, aborted, edited, replay, script, throttled, spoofed
}

/// Pauses a request (before it leaves) or a response (before the client gets it) for editing.
public struct BreakpointRule: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var enabled = true
    /// URL pattern, see `ToolMatch.url`.
    public var pattern: String
    /// Empty means any method.
    public var method = ""
    public var request = true
    public var response = false
    public init(pattern: String, method: String = "", request: Bool = true, response: Bool = false) {
        self.pattern = pattern; self.method = method; self.request = request; self.response = response
    }
}

/// Answers matching requests from Sekisho itself, without contacting the server.
public struct MapLocalRule: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var enabled = true
    public var pattern: String
    public var status = 200
    public var contentType = "application/json"
    public var body = ""
    /// When set, the response body is read from this file at request time.
    public var filePath: String?
    /// When set, the path after the pattern's fixed prefix is looked up in this folder; a missing file goes to the server.
    public var directory: String?
    public init(pattern: String, status: Int = 200, contentType: String = "application/json", body: String = "", filePath: String? = nil) {
        self.pattern = pattern; self.status = status; self.contentType = contentType; self.body = body; self.filePath = filePath
    }
}

extension MapLocalRule {
    /// The file a directory mapping serves for this flow, or nil (no directory, or no such file).
    public func directoryFile(for flow: Flow) -> URL? {
        guard let directory, !directory.isEmpty else { return nil }
        let base = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL
        // The pattern's fixed path prefix: everything before the first wildcard, from the first "/" after the host.
        var prefix = String(pattern.prefix { $0 != "*" && $0 != "?" })
        if let r = prefix.range(of: "://") { prefix = String(prefix[r.upperBound...]) }
        prefix = prefix.firstIndex(of: "/").map { String(prefix[$0...]) } ?? "/"
        var path = flow.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        path = path.removingPercentEncoding ?? path
        guard path.hasPrefix(prefix) else { return nil }
        var relative = String(path.dropFirst(prefix.count))
        if relative.isEmpty || relative.hasSuffix("/") { relative += "index.html" }
        let file = base.appendingPathComponent(relative).standardizedFileURL
        // Never outside the mapped folder: not through ../ in the URL, and not through a symlink inside it.
        let realBase = base.resolvingSymlinksInPath().path
        guard file.path.hasPrefix(base.path + "/"), file.resolvingSymlinksInPath().path.hasPrefix(realBase + "/") else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) && !isDir.boolValue ? file : nil
    }
}

/// Connects to another address for a host, keeping its name in the Host header and TLS (SNI).
public struct DNSRule: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var enabled = true
    public var host: String
    public var address: String
    public init(host: String, address: String) { self.host = host; self.address = address }
}

/// Slows matching traffic: a delay before each request, and bandwidth caps each way.
public struct ThrottleRule: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var enabled = true
    public var pattern: String
    public var latencyMs = 0
    /// Kilobits per second; 0 means no cap.
    public var downKbps = 0
    public var upKbps = 0
    public init(pattern: String, latencyMs: Int = 0, downKbps: Int = 0, upKbps: Int = 0) {
        self.pattern = pattern; self.latencyMs = latencyMs; self.downKbps = downKbps; self.upKbps = upKbps
    }

    public static let presets: [(name: String, latency: Int, down: Int, up: Int)] = [
        ("Edge", 400, 240, 200), ("3G", 300, 780, 330), ("4G / LTE", 60, 12_000, 5_000),
        ("Slow Wi-Fi", 40, 2_000, 1_000), ("Very bad network", 1_000, 50, 20), ("High latency", 1_500, 0, 0),
    ]
}

/// A script (JavaScript) that can change matching requests and responses: Proxyman's onRequest/onResponse shape.
public struct ScriptRule: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var enabled = true
    public var name = "Script"
    public var pattern: String
    public var request = true
    public var response = true
    public var code = ScriptRule.template
    public init(pattern: String, name: String = "Script") { self.pattern = pattern; self.name = name }

    public static let template = """
    // Runs for each matching request before it leaves Sekisho. Change it and return it.
    // request: method, scheme, host, port, path, queries, headers, body (an object for JSON, else a string)
    function onRequest(context, url, request) {
      // request.headers["X-Debug"] = "1";
      return request;
    }

    // Runs once the whole response is in, before the app gets it.
    // response: statusCode, headers, body. context.sharedState persists between calls.
    function onResponse(context, url, request, response) {
      // response.headers["X-Sekisho"] = "scripted";
      return response;
    }
    """
}

/// Listens on a local port and forwards everything to a server, recording it: point an app at localhost instead.
public struct ReverseProxyRule: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var enabled = true
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    public var tls: Bool
    public init(localPort: Int, remoteHost: String, remotePort: Int, tls: Bool) {
        self.localPort = localPort; self.remoteHost = remoteHost; self.remotePort = remotePort; self.tls = tls
    }
}

/// Sends matching requests to another server. Parts left out of `destination` are kept from the original.
public struct MapRemoteRule: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var enabled = true
    public var pattern: String
    /// e.g. `http://localhost:3000` or `https://staging.example.com/v2/users`.
    public var destination: String
    public var preserveHost = false
    public init(pattern: String, destination: String, preserveHost: Bool = false) {
        self.pattern = pattern; self.destination = destination; self.preserveHost = preserveHost
    }

    /// Rewrites `flow`'s target. Returns false when `destination` is not a usable URL.
    public func apply(to flow: inout Flow) -> Bool {
        let dest = destination.contains("://") ? destination : "http://" + destination
        guard let c = URLComponents(string: dest), let host = c.host, !host.isEmpty else { return false }
        let original = flow.url
        let scheme = c.scheme?.lowercased() ?? flow.scheme
        let port = c.port ?? (scheme == flow.scheme && host == flow.host ? flow.port : (scheme == "https" ? 443 : 80))
        if !c.percentEncodedPath.isEmpty && c.percentEncodedPath != "/" || dest.hasSuffix("/") {
            var path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
            if let q = c.percentEncodedQuery { path += "?" + q } else if let q = URLComponents(string: original)?.percentEncodedQuery { path += "?" + q }
            flow.path = path
        }
        flow.scheme = scheme
        flow.host = host
        flow.port = port
        flow.mappedFrom = original
        flow.interventions.insert(.mapRemote)
        if !preserveHost {
            flow.requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Host") == .orderedSame }
            flow.requestHeaders.insert(Flow.Header("Host", flow.authority), at: 0)
        }
        return true
    }
}

public enum ToolMatch {
    /// Glob match (`*`, `?`, case-insensitive) on scheme, host, port and path separately, so a pattern for one host
    /// never matches another host's URL that merely mentions it. Forms: `api.example.com` (any scheme, port, path),
    /// `*.example.com/v1/*`, `https://api.example.com:8443/v1/*`.
    public static func url(_ url: String, _ pattern: String) -> Bool {
        guard let u = URLComponents(string: url), let host = u.host, let scheme = u.scheme else { return false }
        var p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return false }
        var schemePattern = "*"
        if let r = p.range(of: "://") {
            schemePattern = String(p[..<r.lowerBound])
            p = String(p[r.upperBound...])
        }
        let slash = p.firstIndex(of: "/")
        let authority = slash.map { String(p[..<$0]) } ?? p
        let pathPattern = slash.map { String(p[$0...]) } ?? "/*"
        var hostPattern = authority, portPattern: String?
        if let colon = authority.lastIndex(of: ":"), !authority.hasSuffix("]") {
            hostPattern = String(authority[..<colon])
            portPattern = String(authority[authority.index(after: colon)...])
        }
        hostPattern = hostPattern.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = u.port ?? (scheme.lowercased() == "https" ? 443 : 80)
        var path = u.percentEncodedPath.isEmpty ? "/" : u.percentEncodedPath
        if let q = u.percentEncodedQuery { path += "?" + q }
        return glob(schemePattern, scheme) && glob(hostPattern, host)
            && (portPattern.map { glob($0, String(port)) } ?? true) && glob(pathPattern, path)
    }

    private static func glob(_ pattern: String, _ text: String) -> Bool { fnmatch(pattern, text, FNM_CASEFOLD) == 0 }
}

extension ProxyRules {
    func breakpoint(for flow: Flow) -> BreakpointRule? {
        breakpoints.first {
            $0.enabled && ($0.request || $0.response) && ToolMatch.url(flow.url, $0.pattern)
                && ($0.method.isEmpty || $0.method.caseInsensitiveCompare(flow.method) == .orderedSame)
        }
    }
    func mapLocal(for flow: Flow) -> MapLocalRule? { mapLocal.first { $0.enabled && ToolMatch.url(flow.url, $0.pattern) } }
    func mapRemote(for flow: Flow) -> MapRemoteRule? { mapRemote.first { $0.enabled && ToolMatch.url(flow.url, $0.pattern) } }
}

extension Flow {
    static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:")
    static let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// A hostname or IP literal, nothing that could end a request line (CR, LF, space, %).
    public static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && host.unicodeScalars.allSatisfy { hostCharacters.contains($0) }
    }

    public static func isValidMethod(_ method: String) -> Bool {
        !method.isEmpty && method.utf8.count <= 32 && method.unicodeScalars.allSatisfy { tokenCharacters.contains($0) }
    }

    /// Why this request cannot go on the wire as it is (edited at a breakpoint, by a script, or imported), or nil.
    public var wireProblem: String? {
        if !Self.isValidHost(host) { return "The host \"\(host)\" is not a valid hostname" }
        if !Self.isValidMethod(method) { return "The method \"\(method)\" is not a valid HTTP method" }
        for h in requestHeaders {
            if h.name.isEmpty || !h.name.unicodeScalars.allSatisfy({ Self.tokenCharacters.contains($0) }) { return "The header name \"\(h.name)\" is not valid" }
            if h.value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) { return "The \(h.name) header contains a line break" }
        }
        return nil
    }

    /// The request target as it goes on the wire. Browsers send `|`, `^`, `{`, `}` and friends unescaped and servers
    /// accept them, but NIO's request validation refuses them: percent-encode anything outside RFC 3986, keep the rest
    /// (including existing %XX) exactly as sent.
    public static func wireTarget(_ path: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%".utf8)
        var out = ""
        for byte in path.utf8 {
            if allowed.contains(byte) { out.append(Character(UnicodeScalar(byte))) } else { out += String(format: "%%%02X", byte) }
        }
        return out
    }

    /// Replaces the request target from a typed URL. Returns false when it is not an http(s) URL.
    public mutating func setURL(_ text: String) -> Bool {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return false }
        self.scheme = scheme
        self.host = host
        self.port = c.port ?? (scheme == "https" ? 443 : 80)
        var p = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        if let q = c.percentEncodedQuery { p += "?" + q }
        self.path = p
        return true
    }

    /// Headers as editable text, one `Name: value` per line.
    public static func headerText(_ headers: [Header]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    public static func parseHeaders(_ text: String) -> [Header] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }) else { return nil }
            return Header(name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Sets the request body from edited text. The text is plain, so any Content-Encoding is dropped.
    public mutating func setRequestBodyText(_ text: String) {
        requestBody = Data(text.utf8)
        requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
    }

    public mutating func setResponseBodyText(_ text: String) {
        responseBody = Data(text.utf8)
        responseSize = responseBody.count
        responseHeaders.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
    }
}
