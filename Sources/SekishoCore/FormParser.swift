import Foundation

/// Request bodies as forms: urlencoded pairs and multipart parts.
public enum FormParser {
    public static func urlEncoded(_ data: Data) -> [(String, String)] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "&").map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            return (kv.first ?? "", kv.count > 1 ? kv[1] : "")
        }
    }

    public struct Part: Identifiable, Sendable {
        public let id: Int
        public var name = "", filename: String?, contentType: String?
        public var headers: [Header] = []
        public var body = Data()
        public struct Header: Sendable { public var name: String; public var value: String }
    }

    public static func multipart(_ data: Data, contentType: String) -> [Part] {
        guard let range = contentType.range(of: "boundary=") else { return [] }
        var boundary = String(contentType[range.upperBound...]).split(separator: ";").first.map(String.init) ?? ""
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard !boundary.isEmpty else { return [] }
        let delimiter = Data(("--" + boundary).utf8), separator = Data("\r\n\r\n".utf8)
        var parts: [Part] = []
        var cursor = data.startIndex
        var chunks: [Data] = []
        while let r = data.range(of: delimiter, in: cursor..<data.endIndex) {
            if cursor != data.startIndex { chunks.append(data[cursor..<r.lowerBound]) }
            cursor = r.upperBound
        }
        for (i, var chunk) in chunks.enumerated() {
            if chunk.starts(with: Data("\r\n".utf8)) { chunk = chunk.dropFirst(2) }
            if chunk.suffix(2) == Data("\r\n".utf8) { chunk = chunk.dropLast(2) }
            guard let split = chunk.range(of: separator) else { continue }
            var part = Part(id: i)
            for line in String(decoding: chunk[chunk.startIndex..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n") {
                let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                part.headers.append(Part.Header(name: kv[0], value: kv[1]))
                if kv[0].lowercased() == "content-type" { part.contentType = kv[1] }
                if kv[0].lowercased() == "content-disposition" {
                    for attr in kv[1].split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        if attr.hasPrefix("name=") { part.name = attr.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                        if attr.hasPrefix("filename=") { part.filename = attr.dropFirst(9).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                    }
                }
            }
            part.body = Data(chunk[split.upperBound...])
            parts.append(part)
        }
        return parts
    }
}

