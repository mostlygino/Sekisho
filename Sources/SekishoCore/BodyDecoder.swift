import Compression
import Foundation

/// Undoes HTTP Content-Encoding for display: gzip, deflate and br. Anything else (zstd) returns nil.
public enum BodyDecoder {
    public static func decode(_ data: Data, encoding: String?) -> Data? {
        guard let encoding = encoding?.lowercased().trimmingCharacters(in: .whitespaces), !encoding.isEmpty, encoding != "identity" else { return data }
        if data.isEmpty { return data }
        switch encoding {
        case "gzip", "x-gzip": return gunzip(data)
        case "deflate":
            // HTTP deflate is usually zlib-wrapped (RFC 1950); some servers send raw deflate.
            if data.count > 2, data[data.startIndex] & 0x0f == 8, (UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])) % 31 == 0 {
                return inflate(data.dropFirst(2), algorithm: COMPRESSION_ZLIB)
            }
            return inflate(data, algorithm: COMPRESSION_ZLIB)
        case "br": return inflate(data, algorithm: COMPRESSION_BROTLI)
        default: return nil
        }
    }

    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flags & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count else { return nil }
        return inflate(Data(b[i...]), algorithm: COMPRESSION_ZLIB)
    }

    static func inflate(_ input: Data, algorithm: compression_algorithm) -> Data? {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        let chunk = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            stream.src_ptr = base
            stream.src_size = raw.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: chunk - stream.dst_size)
                switch status {
                case COMPRESSION_STATUS_OK: if output.count > 256 << 20 { return nil }
                case COMPRESSION_STATUS_END: return output
                default: return output.isEmpty ? nil : output
                }
            }
        }
    }
}
