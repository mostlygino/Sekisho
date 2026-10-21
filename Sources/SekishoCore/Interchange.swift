import Foundation

// MARK: Sessions

/// A saved session: the flows and the user's marks, versioned so older files keep opening.
public struct SessionFile: Codable, Sendable {
    public var format = "sekisho-session"
    public var version = 1
    public var saved = Date()
    public var flows: [Flow]
    /// Highlight and comment per flow id, opaque to the core (the app owns the shape).
    public var marks: Data?
    /// The app behind each connection id the flows use, so the Apps sidebar comes back too.
    public var apps: [Int: ClientApp]?
    public init(flows: [Flow], marks: Data? = nil, apps: [Int: ClientApp]? = nil) { self.flows = flows; self.marks = marks; self.apps = apps }

    /// ISO 8601 with milliseconds: timings are sub-second.
    static let dateFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Self.dateFormat.string(from: date))
        }
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> SessionFile {
        let d = JSONDecoder()
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormat.date(from: text) ?? plain.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
            }
            return date
        }
        let file = try d.decode(SessionFile.self, from: data)
        guard file.format == "sekisho-session" else { throw CocoaError(.fileReadCorruptFile) }
        return file
    }
}

// MARK: Import

public enum Import {
    /// HAR 1.2 entries as flows (ids from 1; the caller renumbers). Bodies with `encoding: base64` are decoded.
    public static func har(_ data: Data) throws -> [Flow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = root["log"] as? [String: Any], let entries = log["entries"] as? [[String: Any]]
        else { throw CocoaError(.fileReadCorruptFile) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return entries.enumerated().compactMap { i, e in
            guard let req = e["request"] as? [String: Any], let url = req["url"] as? String else { return nil }
            var f = Flow(id: i + 1)
            guard f.setURL(url) else { return nil }
            f.imported = true
            f.method = (req["method"] as? String) ?? "GET"
            f.httpVersion = (req["httpVersion"] as? String).map { $0.uppercased().hasPrefix("HTTP/") ? $0.uppercased() : "HTTP/1.1" } ?? "HTTP/1.1"
            f.requestHeaders = headers(req["headers"])
            if let post = req["postData"] as? [String: Any], let text = post["text"] as? String { f.requestBody = Data(text.utf8) }
            if let started = e["startedDateTime"] as? String, let date = iso.date(from: started) ?? plain.date(from: started) { f.started = date }
            // HAR uses -1 for "unknown".
            if let ms = e["time"] as? Double, ms >= 0 { f.ended = f.started.addingTimeInterval(ms / 1000) } else { f.ended = f.started }
            if let res = e["response"] as? [String: Any] {
                if let status = res["status"] as? Int, status > 0 { f.status = status }
                f.reason = (res["statusText"] as? String) ?? ""
                f.responseHeaders = headers(res["headers"])
                if let content = res["content"] as? [String: Any], let text = content["text"] as? String {
                    f.responseBody = (content["encoding"] as? String) == "base64" ? (Data(base64Encoded: text) ?? Data()) : Data(text.utf8)
                    // HAR bodies are already decoded: the header would make the viewer try to undo it again.
                    f.responseHeaders.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
                    f.responseSize = f.responseBody.count
                }
            }
            if let comment = e["comment"] as? String, !comment.isEmpty { f.error = comment }
            return f
        }
    }

    private static func headers(_ value: Any?) -> [Flow.Header] {
        ((value as? [[String: Any]]) ?? []).compactMap { h in
            guard let name = h["name"] as? String, !name.hasPrefix(":") else { return nil }
            return Flow.Header(name, (h["value"] as? String) ?? "")
        }
    }

    /// A curl command line as a request: -X, -H, -d/--data*, -u, -A, -b, -e, -I, --url and the URL itself.
    public static func curl(_ command: String) -> Flow? {
        let words = shellWords(command)
        guard let first = words.first, first == "curl" || first.hasSuffix("/curl") else { return nil }
        var f = Flow(id: 0)
        var method: String?, url: String?, body: [String] = [], headers: [Flow.Header] = []
        var i = 1
        func next() -> String? { i += 1; return i < words.count ? words[i] : nil }
        while i < words.count {
            let w = words[i]
            switch w {
            case "-X", "--request": method = next()
            case "-H", "--header":
                if let h = next(), let colon = h.firstIndex(of: ":") {
                    headers.append(Flow.Header(String(h[..<colon]).trimmingCharacters(in: .whitespaces),
                                               String(h[h.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode": if let d = next() { body.append(d) }
            case "-u", "--user": if let u = next() { headers.append(Flow.Header("Authorization", "Basic " + Data(u.utf8).base64EncodedString())) }
            case "-A", "--user-agent": if let a = next() { headers.append(Flow.Header("User-Agent", a)) }
            case "-b", "--cookie": if let c = next() { headers.append(Flow.Header("Cookie", c)) }
            case "-e", "--referer": if let r = next() { headers.append(Flow.Header("Referer", r)) }
            case "-I", "--head": method = "HEAD"
            case "--url": url = next()
            case "-F", "--form": if let d = next() { body.append(d) }
            default:
                if Self.curlValueOptions.contains(w) { _ = next() }
                else if !w.hasPrefix("-") {
                    // The first word with a scheme wins; otherwise the first bare word.
                    if w.contains("://") { if url == nil || !(url!.contains("://")) { url = w } } else if url == nil { url = w }
                }
            }
            i += 1
        }
        guard let url, f.setURL(url.contains("://") ? url : "http://" + url) else { return nil }
        f.requestHeaders = headers
        if !body.isEmpty {
            f.requestBody = Data(body.joined(separator: "&").utf8)
            if !headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                f.requestHeaders.append(Flow.Header("Content-Type", "application/x-www-form-urlencoded"))
            }
        }
        f.method = (method ?? (body.isEmpty ? "GET" : "POST")).uppercased()
        return f
    }

    /// curl options that take a value we do not use: skip the value so it is not mistaken for the URL.
    static let curlValueOptions: Set<String> = [
        "-o", "--output", "-x", "--proxy", "-w", "--write-out", "--max-time", "-m", "--connect-timeout", "--cacert", "-E", "--cert",
        "--key", "--retry", "--retry-delay", "--retry-max-time", "--resolve", "--connect-to", "-T", "--upload-file", "-r", "--range",
        "--limit-rate", "-c", "--cookie-jar", "-D", "--dump-header", "--interface", "-K", "--config", "--proxy-user", "-U",
        "--max-redirs", "--keepalive-time", "--expect100-timeout", "--trace", "--trace-ascii", "--unix-socket", "-Y", "-y",
    ]

    /// POSIX-ish shell word splitting: single quotes literal, double quotes with \ escapes, backslash-newline joins.
    static func shellWords(_ s: String) -> [String] {
        var words: [String] = [], current = "", inWord = false
        var quote: Character?
        var chars = Array(s.replacingOccurrences(of: "\\\n", with: " ")).makeIterator()
        while let c = chars.next() {
            // $'…' (what Chrome's "Copy as cURL (bash)" writes): backslash escapes inside single quotes.
            if quote == nil, c == "$" {
                var look = chars
                if look.next() == "'" {
                    chars = look
                    inWord = true
                    while let d = chars.next(), d != "'" {
                        if d == "\\", let e = chars.next() {
                            switch e {
                            case "n": current.append("\n")
                            case "t": current.append("\t")
                            case "r": current.append("\r")
                            default: current.append(e)
                            }
                        } else { current.append(d) }
                    }
                    continue
                }
            }
            if let q = quote {
                if c == q { quote = nil }
                else if q == "\"" && c == "\\", let n = chars.next() { current.append(n) }
                else { current.append(c) }
            } else if c == "'" || c == "\"" { quote = c; inWord = true }
            else if c == "\\", let n = chars.next() { current.append(n); inWord = true }
            else if c.isWhitespace { if inWord { words.append(current); current = ""; inWord = false } }
            else { current.append(c); inWord = true }
        }
        if inWord { words.append(current) }
        return words
    }
}

// MARK: Code generators

public enum CodeLanguage: String, CaseIterable, Sendable {
    case curl = "cURL", httpie = "HTTPie", python = "Python requests", fetch = "JavaScript fetch", axios = "Node axios",
         urlSession = "Swift URLSession", go = "Go net/http"
}

public enum CodeGen {
    static let skip: Set<String> = ["content-length", "connection", "proxy-connection", "keep-alive", "transfer-encoding", "host", "accept-encoding"]

    static func headers(_ f: Flow) -> [Flow.Header] { f.requestHeaders.filter { !skip.contains($0.name.lowercased()) } }
    static func bodyText(_ f: Flow) -> String? {
        f.requestBody.isEmpty ? nil : String(data: f.decodedRequestBody ?? f.requestBody, encoding: .utf8)
    }

    /// A string literal for C-family languages (JS, Swift, Go, Python): quotes, backslashes, newlines and controls escaped.
    static func literal(_ s: String, swift: Bool = false) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // Controls and bidi overrides escaped (Swift spells it \u{…}); everything else as is.
                if u.value < 0x20 || u.value == 0x7F || (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value) {
                    out += swift ? "\\u{\(String(u.value, radix: 16))}" : String(format: "\\u%04x", u.value)
                } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func swiftLiteral(_ s: String) -> String { literal(s, swift: true) }

    public static func generate(_ f: Flow, _ language: CodeLanguage) -> String {
        let hs = headers(f), body = bodyText(f), url = f.url, method = f.method
        switch language {
        case .curl:
            return Export.curl(f)
        case .httpie:
            var parts = ["http", "--ignore-stdin", method, Export.quote(url)]
            parts += hs.map { Export.quote("\($0.name):\($0.value)") }
            var out = parts.joined(separator: " \\\n  ")
            if let body { out = "printf '%s' \(Export.quote(body)) | " + out.replacingOccurrences(of: "--ignore-stdin ", with: "") }
            return out
        case .python:
            var lines = ["import requests", "", "headers = {"]
            lines += hs.map { "    \(literal($0.name)): \(literal($0.value))," }
            lines += ["}", ""]
            lines.append("response = requests.request(\n    \(literal(method)),\n    \(literal(url)),\n    headers=headers,"
                + (body.map { "\n    data=\(literal($0)).encode()," } ?? "") + "\n)")
            lines.append("print(response.status_code, response.text)")
            return lines.joined(separator: "\n")
        case .fetch:
            var opts = ["  method: \(literal(method)),", "  headers: {"]
            opts += hs.map { "    \(literal($0.name)): \(literal($0.value))," }
            opts.append("  },")
            if let body { opts.append("  body: \(literal(body)),") }
            return "const response = await fetch(\(literal(url)), {\n" + opts.joined(separator: "\n") + "\n});\nconsole.log(response.status, await response.text());"
        case .axios:
            var opts = ["  method: \(literal(method.lowercased())),", "  url: \(literal(url)),", "  headers: {"]
            opts += hs.map { "    \(literal($0.name)): \(literal($0.value))," }
            opts.append("  },")
            if let body { opts.append("  data: \(literal(body)),") }
            opts.append("  transformResponse: [(data) => data],")
            return "const axios = require(\"axios\");\n\nconst response = await axios({\n" + opts.joined(separator: "\n") + "\n});\nconsole.log(response.status, response.data);"
        case .urlSession:
            var lines = ["import Foundation", "", "var request = URLRequest(url: URL(string: \(swiftLiteral(url)))!)",
                         "request.httpMethod = \(swiftLiteral(method))"]
            lines += hs.map { "request.setValue(\(swiftLiteral($0.value)), forHTTPHeaderField: \(swiftLiteral($0.name)))" }
            if let body { lines.append("request.httpBody = Data(\(swiftLiteral(body)).utf8)") }
            lines += ["", "let (data, response) = try await URLSession.shared.data(for: request)",
                      "print((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))"]
            return lines.joined(separator: "\n")
        case .go:
            var lines = ["package main", "", "import (", "\t\"fmt\"", "\t\"io\"", "\t\"net/http\"", body != nil ? "\t\"strings\"" : nil, ")", "",
                         "func main() {"].compactMap { $0 }
            lines.append("\treq, err := http.NewRequest(\(literal(method)), \(literal(url)), " + (body.map { "strings.NewReader(\(literal($0))))" } ?? "nil)"))
            lines.append("\tif err != nil {\n\t\tpanic(err)\n\t}")
            lines += hs.map { "\treq.Header.Set(\(literal($0.name)), \(literal($0.value)))" }
            lines += ["\tres, err := http.DefaultClient.Do(req)", "\tif err != nil {\n\t\tpanic(err)\n\t}", "\tdefer res.Body.Close()",
                      "\tbody, _ := io.ReadAll(res.Body)", "\tfmt.Println(res.StatusCode, string(body))", "}"]
            return lines.joined(separator: "\n")
        }
    }
}

// MARK: Diff

public struct DiffRow: Sendable, Hashable {
    public enum Kind: Sendable { case same, removed, added, changed }
    public var kind: Kind
    public var left: String?
    public var right: String?
}

public enum TextDiff {
    /// Line diff aligned for side-by-side display: a removal next to an addition becomes one changed row.
    public static func rows(_ a: String, _ b: String) -> [DiffRow] {
        let left = a.components(separatedBy: "\n"), right = b.components(separatedBy: "\n")
        let diff = right.difference(from: left)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [DiffRow] = []
        var i = 0, j = 0
        while i < left.count || j < right.count {
            let gone = i < left.count && removed.contains(i), new = j < right.count && inserted.contains(j)
            if gone && new { rows.append(DiffRow(kind: .changed, left: left[i], right: right[j])); i += 1; j += 1 }
            else if gone { rows.append(DiffRow(kind: .removed, left: left[i], right: nil)); i += 1 }
            else if new { rows.append(DiffRow(kind: .added, left: nil, right: right[j])); j += 1 }
            else if i < left.count && j < right.count { rows.append(DiffRow(kind: .same, left: left[i], right: right[j])); i += 1; j += 1 }
            else { break }
        }
        return rows
    }

    /// One flow as comparable text: request line, headers, body, then the response.
    public static func text(_ f: Flow) -> String {
        var lines = ["\(f.method) \(f.url)"]
        lines += f.requestHeaders.map { "\($0.name): \($0.value)" }
        if let body = String(data: f.decodedRequestBody ?? f.requestBody, encoding: .utf8), !body.isEmpty {
            lines += ["", BodyText.prettyJSON(f.decodedRequestBody ?? f.requestBody) ?? body]
        }
        lines += ["", "──── response ────", f.status.map { "\($0) \(f.reason)" } ?? (f.error ?? "no response")]
        lines += f.responseHeaders.map { "\($0.name): \($0.value)" }
        let data = f.decodedResponseBody ?? f.responseBody
        if let body = String(data: data.prefix(2 << 20), encoding: .utf8), !body.isEmpty {
            lines += ["", BodyText.prettyJSON(data) ?? body]
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: WebSocket frames

/// Reads RFC 6455 frames from one direction of an upgraded connection: unmasks client frames,
/// joins continuation frames, reports control frames. Compressed frames (permessage-deflate) are not expected:
/// Sekisho strips Sec-WebSocket-Extensions from the upgrade.
public struct WebSocketFrames: Sendable {
    private var buffer = Data()
    private var fragments = Data()
    private var fragmentKind: Flow.Message.Kind?
    /// Set once the stream stops looking like WebSocket frames; nothing more is parsed.
    public private(set) var broken = false
    /// Larger frames or messages are not recorded (the bytes still flow through untouched).
    public static let maxMessage = 16 << 20
    /// Bytes still owed by the HTTP 101 response on the server side; frames start after it.
    public var skipHeaderUntilBlankLine: Bool

    public init(afterHTTPHeader: Bool) { skipHeaderUntilBlankLine = afterHTTPHeader }

    public mutating func feed(_ data: Data) -> [(Flow.Message.Kind, Data, Int)] {
        guard !broken else { return [] }
        buffer.append(data)
        if buffer.count > Self.maxMessage + 16 { broken = true; buffer = Data(); return [] }
        if skipHeaderUntilBlankLine {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return [] }
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            skipHeaderUntilBlankLine = false
        }
        var out: [(Flow.Message.Kind, Data, Int)] = []
        while true {
            let b = [UInt8](buffer.prefix(14))
            guard b.count >= 2 else { break }
            let fin = b[0] & 0x80 != 0, opcode = b[0] & 0x0F, masked = b[1] & 0x80 != 0
            var length = Int(b[1] & 0x7F), offset = 2
            if length == 126 { guard b.count >= 4 else { break }; length = Int(b[2]) << 8 | Int(b[3]); offset = 4 }
            else if length == 127 {
                guard b.count >= 10 else { break }
                // The top bit must be 0 (RFC 6455); anything above the cap is not recorded.
                guard b[2] & 0x80 == 0 else { broken = true; buffer = Data(); break }
                let wide = b[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard wide <= UInt64(Self.maxMessage) else { broken = true; buffer = Data(); break }
                length = Int(wide)
                offset = 10
            }
            let keyLength = masked ? 4 : 0
            guard length <= Self.maxMessage else { broken = true; buffer = Data(); break }
            guard buffer.count - offset - keyLength >= length else { break }
            let start = buffer.startIndex
            var payload = Data(buffer[(start + offset + keyLength)..<(start + offset + keyLength + length)])
            if masked {
                let key = [UInt8](buffer[(start + offset)..<(start + offset + 4)])
                payload = Data(payload.enumerated().map { $1 ^ key[$0 % 4] })
            }
            buffer.removeSubrange(start..<(start + offset + keyLength + length))
            switch opcode {
            case 0x0:
                guard fragmentKind != nil, fragments.count + payload.count <= Self.maxMessage else {
                    fragments = Data(); fragmentKind = nil; continue
                }
                fragments.append(payload)
                if fin, let kind = fragmentKind { out.append((kind, fragments, fragments.count)); fragments = Data(); fragmentKind = nil }
            case 0x1, 0x2:
                let kind: Flow.Message.Kind = opcode == 1 ? .text : .binary
                if fin { out.append((kind, payload, payload.count)) } else { fragmentKind = kind; fragments = payload }
            case 0x8: out.append((.close, payload, payload.count))
            case 0x9: out.append((.ping, payload, payload.count))
            case 0xA: out.append((.pong, payload, payload.count))
            default: broken = true; buffer = Data(); return out
            }
        }
        return out
    }
}
