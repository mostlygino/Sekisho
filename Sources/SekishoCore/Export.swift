import Foundation

public enum Export {
    /// A curl command that repeats the request. Hop-by-hop and length headers are left to curl.
    public static func curl(_ f: Flow) -> String {
        // --globoff: [] and {} in a URL are literal, not curl ranges.
        var parts = ["curl", "--globoff"]
        if f.method != "GET" || !f.requestBody.isEmpty { parts.append("-X \(quote(f.method))") }
        parts.append(quote(f.url))
        let skip: Set<String> = ["content-length", "connection", "proxy-connection", "keep-alive", "transfer-encoding"]
        for h in f.requestHeaders where !skip.contains(h.name.lowercased()) {
            parts.append("-H \(quote("\(h.name): \(h.value)"))")
        }
        if f.requestHeader("Accept-Encoding") != nil { parts.append("--compressed") }
        if !f.requestBody.isEmpty {
            if let text = String(data: f.requestBody, encoding: .utf8) {
                // --data-raw: a body starting with @ must stay text, not become "read this file".
                parts.append("--data-raw \(quote(text))")
            } else {
                parts.append("--data-binary @request.bin")
            }
        }
        return parts.joined(separator: " \\\n  ")
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// HAR 1.2, readable by browsers' dev tools, Proxyman and Charles. Tunnels have no HTTP to export and are skipped.
    public static func har(_ flows: [Flow], version: String = "1.0") throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries: [[String: Any]] = flows.filter { $0.kind == .http }.map { f in
            let ms = (f.duration ?? 0) * 1000
            var request: [String: Any] = [
                "method": f.method, "url": f.url, "httpVersion": f.httpVersion,
                "headers": f.requestHeaders.map { ["name": $0.name, "value": $0.value] },
                "queryString": f.queryItems.map { ["name": $0.name, "value": $0.value ?? ""] },
                "cookies": f.requestCookies.map { ["name": $0.0, "value": $0.1] },
                "headersSize": -1, "bodySize": f.requestBody.count,
            ]
            if !f.requestBody.isEmpty {
                request["postData"] = ["mimeType": f.requestHeader("Content-Type") ?? "", "text": String(decoding: f.decodedRequestBody ?? f.requestBody, as: UTF8.self)]
            }
            var content: [String: Any] = ["size": f.responseSize, "mimeType": f.responseHeader("Content-Type") ?? ""]
            let body = f.decodedResponseBody ?? f.responseBody
            if let text = String(data: body, encoding: .utf8) {
                content["text"] = text
            } else if !body.isEmpty {
                content["text"] = body.base64EncodedString()
                content["encoding"] = "base64"
            }
            var entry: [String: Any] = [
                "startedDateTime": iso.string(from: f.started), "time": ms,
                "request": request,
                "response": [
                    "status": f.status ?? 0, "statusText": f.reason, "httpVersion": f.httpVersion,
                    "headers": f.responseHeaders.map { ["name": $0.name, "value": $0.value] },
                    "cookies": [Any](), "content": content,
                    "redirectURL": f.responseHeader("Location") ?? "", "headersSize": -1, "bodySize": f.responseSize,
                ],
                "cache": [String: Any](),
                "timings": ["send": 0, "wait": ms, "receive": 0],
            ]
            if let error = f.error { entry["comment"] = error }
            return entry
        }
        let log: [String: Any] = ["log": ["version": "1.2", "creator": ["name": "Sekisho", "version": version], "entries": entries]]
        return try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
