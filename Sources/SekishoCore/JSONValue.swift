import Foundation

/// JSON as it was sent: object keys keep their order, numbers keep their spelling (no 39.950000000000003),
/// strings keep their escapes. Foundation's JSONSerialization keeps none of that, and a debugging proxy has to.
public indirect enum JSONValue: Sendable, Equatable {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    /// The decoded text and the literal as sent (with its quotes and escapes).
    case string(String, raw: String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.array(x), .array(y)): x == y
        case let (.string(x, _), .string(y, _)): x == y
        case let (.number(x), .number(y)): x == y
        case let (.bool(x), .bool(y)): x == y
        case (.null, .null): true
        default: false
        }
    }

    /// Parses JSON text; nil when it is not JSON (or nests deeper than 512).
    public static func parse(_ data: Data) -> JSONValue? {
        var parser = Parser(bytes: [UInt8](data))
        parser.skip()
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skip()
        return parser.i == parser.bytes.count ? value : nil
    }

    /// Two-space indentation, `"key": value`, empty containers kept on one line.
    public func pretty() -> String {
        var out = ""
        write(&out, indent: 0)
        return out
    }

    private func write(_ out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1), close = String(repeating: "  ", count: indent)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (n, m) in members.enumerated() {
                out += pad + JSONValue.quote(m.key) + ": "
                m.value.write(&out, indent: indent + 1)
                out += n < members.count - 1 ? ",\n" : "\n"
            }
            out += close + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (n, item) in items.enumerated() {
                out += pad
                item.write(&out, indent: indent + 1)
                out += n < items.count - 1 ? ",\n" : "\n"
            }
            out += close + "]"
        case .string(_, let raw): out += raw
        case .number(let n): out += n
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skip() { while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 } }

        mutating func value(depth: Int) -> JSONValue? {
            guard depth < 512, i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1; skip()
                var members: [(key: String, value: JSONValue)] = []
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                while true {
                    skip()
                    guard case .string(let key, _)? = string() else { return nil }
                    skip()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                    i += 1; skip()
                    guard let v = value(depth: depth + 1) else { return nil }
                    members.append((key, v))
                    skip()
                    guard i < bytes.count else { return nil }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                    return nil
                }
            case UInt8(ascii: "["):
                i += 1; skip()
                var items: [JSONValue] = []
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skip()
                    guard let v = value(depth: depth + 1) else { return nil }
                    items.append(v)
                    skip()
                    guard i < bytes.count else { return nil }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    return nil
                }
            case UInt8(ascii: "\""): return string()
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ v: JSONValue) -> JSONValue? {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { return nil }
            i += w.count
            return v
        }

        mutating func number() -> JSONValue? {
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            var digits = 0
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1; digits += 1 }
            guard digits > 0 else { return nil }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                var frac = 0
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1; frac += 1 }
                guard frac > 0 else { return nil }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                var exp = 0
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1; exp += 1 }
                guard exp > 0 else { return nil }
            }
            return .number(String(decoding: bytes[start..<i], as: UTF8.self))
        }

        mutating func string() -> JSONValue? {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { return nil }
            let start = i
            i += 1
            var decoded = [UInt8]()
            var scalars = ""
            func flush() { if !decoded.isEmpty { scalars += String(decoding: decoded, as: UTF8.self); decoded.removeAll() } }
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    flush()
                    return .string(scalars, raw: String(decoding: bytes[start..<i], as: UTF8.self))
                }
                if c < 0x20 { return nil }
                if c == UInt8(ascii: "\\") {
                    guard i + 1 < bytes.count else { return nil }
                    let e = bytes[i + 1]
                    i += 2
                    switch e {
                    case UInt8(ascii: "n"): decoded.append(0x0A)
                    case UInt8(ascii: "t"): decoded.append(0x09)
                    case UInt8(ascii: "r"): decoded.append(0x0D)
                    case UInt8(ascii: "b"): decoded.append(0x08)
                    case UInt8(ascii: "f"): decoded.append(0x0C)
                    case UInt8(ascii: "u"):
                        guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else { return nil }
                        i += 4
                        flush()
                        // Surrogate pairs combine; a lone surrogate becomes U+FFFD.
                        if (0xD800...0xDBFF).contains(v), i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u"),
                           let low = UInt32(String(decoding: bytes[(i + 2)..<(i + 6)], as: UTF8.self), radix: 16), (0xDC00...0xDFFF).contains(low) {
                            i += 6
                            scalars.unicodeScalars.append(UnicodeScalar(0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)) ?? "\u{FFFD}")
                        } else {
                            scalars.unicodeScalars.append(UnicodeScalar(v) ?? "\u{FFFD}")
                        }
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): decoded.append(e)
                    default: return nil
                    }
                    continue
                }
                decoded.append(c)
                i += 1
            }
            return nil
        }
    }
}
