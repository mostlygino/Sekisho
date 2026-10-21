import Foundation

/// One request through the proxy: an HTTP exchange, an opaque HTTPS tunnel, or an upgraded (WebSocket) connection.
public struct Flow: Identifiable, Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case http, tunnel, upgrade }

    public var id: Int
    public var kind: Kind = .http
    public var started = Date()
    public var ended: Date?
    public var scheme = "http"
    public var method = "GET"
    public var host = ""
    public var port = 80
    /// Origin-form target: path plus query.
    public var path = "/"
    public var httpVersion = "HTTP/1.1"
    public var requestHeaders: [Header] = []
    public var requestBody = Data()
    public var status: Int?
    public var reason = ""
    public var responseHeaders: [Header] = []
    public var responseBody = Data()
    /// The captured body stopped at `Flow.captureLimit`; the client still got all of it.
    public var responseTruncated = false
    public var responseSize = 0
    public var error: String?
    public var interventions: Set<Intervention> = []
    /// The original URL when Map Remote sent the request elsewhere.
    public var mappedFrom: String?
    /// The client's source port on loopback.
    public var clientPort: Int?
    /// The client connection this exchange came in on; the app behind it is reported per connection.
    public var connection: Int?
    /// Bytes each way for tunnels and upgraded connections.
    public var bytesUp = 0
    public var bytesDown = 0
    /// When each phase of the exchange happened, for the Summary tab.
    public var timing = Timing()
    /// WebSocket messages, both ways, once the upgrade went through (capped at `messageLimit`).
    public var messages: [Message] = []
    /// Set on flows that came from a HAR file or a saved session rather than the wire.
    public var imported = false

    public static let messageLimit = 5_000

    public struct Timing: Sendable, Hashable, Codable {
        public var connectStart: Date?
        public var connected: Date?
        public var secured: Date?
        public var sent: Date?
        public var firstByte: Date?
        public init() {}
    }

    public struct Message: Sendable, Hashable, Codable, Identifiable {
        public enum Direction: String, Sendable, Codable { case sent, received }
        public enum Kind: String, Sendable, Codable { case text, binary, ping, pong, close }
        public var id: Int
        public var direction: Direction
        public var kind: Kind
        public var time: Date
        public var payload: Data
        public var length: Int
        public init(id: Int, direction: Direction, kind: Kind, time: Date, payload: Data, length: Int) {
            self.id = id; self.direction = direction; self.kind = kind; self.time = time; self.payload = payload; self.length = length
        }
    }

    public static let captureLimit = 32 << 20

    public init(id: Int) { self.id = id }

    public struct Header: Sendable, Hashable, Codable {
        public var name: String
        public var value: String
        public init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }

    public var blocked: Bool {
        get { interventions.contains(.block) }
        set { if newValue { interventions.insert(.block) } else { interventions.remove(.block) } }
    }

    public var isComplete: Bool { ended != nil }

    /// What kind of content this is, for the filter chips.
    public enum Category: String, CaseIterable, Sendable {
        case json = "JSON", xml = "XML", form = "Form", js = "JS", css = "CSS", document = "Document", media = "Media",
             font = "Font", graphql = "GraphQL", websocket = "WebSocket", other = "Other"
    }

    public var category: Category {
        if kind == .upgrade { return .websocket }
        if kind == .tunnel { return .other }
        if graphQLOperation != nil || path.lowercased().contains("graphql") { return .graphql }
        let request = (requestHeader("Content-Type") ?? "").lowercased()
        if request.contains("x-www-form-urlencoded") || request.contains("multipart/form-data") { return .form }
        let t = contentType
        if t.contains("json") { return .json }
        if t.contains("xml") && !t.contains("html") { return .xml }
        if t.contains("javascript") || t.contains("ecmascript") { return .js }
        if t == "text/css" { return .css }
        if t.contains("html") { return .document }
        if t.hasPrefix("image/") || t.hasPrefix("video/") || t.hasPrefix("audio/") { return .media }
        if t.hasPrefix("font/") || t.contains("woff") || t.contains("opentype") || t.contains("truetype") { return .font }
        return .other
    }

    /// The GraphQL operation name, from a JSON request body with `query` (and `operationName` when given).
    public var graphQLOperation: String? {
        guard requestBody.count < 1 << 20, (requestHeader("Content-Type") ?? "").lowercased().contains("json"),
              let object = try? JSONSerialization.jsonObject(with: decodedRequestBody ?? requestBody) as? [String: Any],
              let query = object["query"] as? String else { return nil }
        if let name = object["operationName"] as? String, !name.isEmpty { return name }
        // `query Name(...)` / `mutation Name {`: the word after the keyword.
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        if let k = words.firstIndex(where: { ["query", "mutation", "subscription"].contains($0) }), k + 1 < words.count {
            return String(words[k + 1])
        }
        return "anonymous"
    }

    // Non-optional keys for sorting the list.
    public var sortStatus: Int { status ?? (error != nil ? 999 : -1) }
    public var sortDuration: Double { duration ?? -1 }
    public var sortSize: Int { kind == .http ? responseSize : bytesDown }
    public var duration: TimeInterval? { ended.map { $0.timeIntervalSince(started) } }

    public var defaultPort: Bool { (scheme == "https" && port == 443) || (scheme == "http" && port == 80) }
    public var authority: String { defaultPort ? host : "\(host):\(port)" }
    public var url: String { kind == .tunnel ? "\(host):\(port)" : "\(scheme)://\(authority)\(path)" }

    public var queryItems: [URLQueryItem] { URLComponents(string: url)?.queryItems ?? [] }

    public func requestHeader(_ name: String) -> String? {
        requestHeaders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    public func responseHeader(_ name: String) -> String? {
        responseHeaders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var requestCookies: [(String, String)] {
        (requestHeader("Cookie") ?? "").split(separator: ";").compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return pair.first.map { ($0, pair.count > 1 ? pair[1] : "") }
        }
    }
    public var responseCookies: [String] {
        responseHeaders.filter { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame }.map(\.value)
    }

    /// Response body with Content-Encoding undone, for display. Nil when the encoding is unknown.
    public var decodedResponseBody: Data? {
        BodyDecoder.decode(responseBody, encoding: responseHeader("Content-Encoding"))
    }
    public var decodedRequestBody: Data? {
        BodyDecoder.decode(requestBody, encoding: requestHeader("Content-Encoding"))
    }

    public var contentType: String {
        (responseHeader("Content-Type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    public var rawRequest: String {
        var lines = ["\(method) \(path) \(httpVersion)"]
        lines += requestHeaders.map { "\($0.name): \($0.value)" }
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + BodyText.string(decodedRequestBody ?? requestBody)
    }

    public var rawResponse: String {
        guard let status else { return error ?? "" }
        var lines = ["\(httpVersion) \(status) \(reason)"]
        lines += responseHeaders.map { "\($0.name): \($0.value)" }
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + BodyText.string(decodedResponseBody ?? responseBody)
    }
}

public enum BodyText {
    /// UTF-8 text, or a short note for binary bodies.
    public static func string(_ data: Data) -> String {
        if data.isEmpty { return "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        return "<\(data.count) bytes of binary data>"
    }

    /// Re-indented JSON with key order and number spelling as sent; nil when it is not JSON.
    public static func prettyJSON(_ data: Data) -> String? {
        guard data.count < 16 << 20, let value = JSONValue.parse(data) else { return nil }
        // A bare string or number is JSON too, but "pretty" would only add quotes to plain text.
        switch value {
        case .object, .array: return value.pretty()
        default: return nil
        }
    }

    public static func hexDump(_ data: Data, limit: Int = 64 << 10) -> String {
        var out = ""
        let bytes = [UInt8](data.prefix(limit))
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(row.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
            out += String(format: "%08x  ", offset) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + ascii + "\n"
        }
        if data.count > limit { out += "… \(data.count - limit) more bytes\n" }
        return out
    }
}
