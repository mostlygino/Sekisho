import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Security
import SwiftASN1
import X509
import XCTest
@testable import SekishoCore

final class ProxyTests: XCTestCase {
    func testLeafIsTrustedByMacOSWithRootAsAnchor() throws {
        let ca = try CertificateAuthority()
        for host in ["example.com", "127.0.0.1"] {
            var serializer = DER.Serializer()
            try serializer.serialize(try ca.leafCertificate(for: host))
            let leaf = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData)!
            let root = SecCertificateCreateWithData(nil, Data(ca.rootDER) as CFData)!
            var trust: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
            SecTrustSetAnchorCertificates(trust!, [root] as CFArray)
            var error: CFError?
            XCTAssertTrue(SecTrustEvaluateWithError(trust!, &error), "\(host): \(String(describing: error))")
        }
    }

    func testCAPersistsWithPrivateKeyFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try CertificateAuthority(directory: dir)
        let second = try CertificateAuthority(directory: dir)
        XCTAssertEqual(first.rootPEM, second.rootPEM)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("root-key.pem").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testRules() {
        let rules = ProxyRules(sslProxying: ["*.example.com"], blocked: ["ads.test"])
        XCTAssertTrue(rules.intercepts("api.example.com"))
        XCTAssertTrue(rules.intercepts("example.com"))
        XCTAssertFalse(rules.intercepts("badexample.com"))
        XCTAssertTrue(rules.blocks("ADS.test"))
        XCTAssertTrue(ProxyRules(sslProxying: ["*"]).intercepts("anything"))
        XCTAssertEqual(ProxyHandler.splitAuthority("[::1]:8443", defaultPort: 443)?.0, "::1")
        XCTAssertNil(ProxyHandler.splitAuthority("host:99999", defaultPort: 443))
    }

    func testBodyDecoding() throws {
        let text = String(repeating: "sekisho ", count: 200)
        let gz = try run("/bin/sh", ["-c", "printf '%s' \"$0\" | gzip -c", text])
        XCTAssertEqual(BodyDecoder.decode(gz, encoding: "gzip").map { String(decoding: $0, as: UTF8.self) }, text)
        XCTAssertEqual(BodyDecoder.decode(Data("plain".utf8), encoding: nil), Data("plain".utf8))
        XCTAssertNil(BodyDecoder.decode(Data([1, 2, 3]), encoding: "zstd"))
    }

    // MARK: End to end, through curl

    func testProxyEndToEnd() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let originCA = try CertificateAuthority()
        let plain = try startOrigin(group: group, tls: nil)
        let secure = try startOrigin(group: group, tls: try originCA.serverContext(for: "localhost"))
        defer { try? plain.close().wait(); try? secure.close().wait() }
        let plainPort = plain.localAddress!.port!, securePort = secure.localAddress!.port!

        var upstream = TLSConfiguration.makeClientConfiguration()
        var serializer = DER.Serializer()
        try serializer.serialize(originCA.rootCertificate)
        upstream.trustRoots = .certificates([try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)])

        let flows = NIOLockedValueBox<[Int: Flow]>([:])
        let ca = try CertificateAuthority()
        let proxy = try ProxyServer(port: 0, ca: ca, rules: ProxyRules(sslProxying: ["localhost"], blocked: ["blocked.test"]),
                                    upstreamTLS: upstream) { flow in flows.withLockedValue { $0[flow.id] = flow } }
        try proxy.start()
        defer { proxy.stop() }
        let proxyURL = "http://127.0.0.1:\(proxy.port)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sekishoPEM = dir.appendingPathComponent("sekisho.pem")
        try ca.rootPEM.write(to: sekishoPEM, atomically: true, encoding: .utf8)

        func curl(_ args: [String]) throws -> String {
            String(decoding: try run("/usr/bin/curl", ["-sS", "--max-time", "10", "-x", proxyURL] + args), as: UTF8.self)
        }

        // Plain HTTP, with a body.
        XCTAssertEqual(try curl(["-d", "ping", "http://127.0.0.1:\(plainPort)/plain?x=1"]), "POST /plain?x=1 ping")
        // HTTPS, decrypted with a Sekisho leaf; curl trusts only the Sekisho CA.
        XCTAssertEqual(try curl(["--cacert", sekishoPEM.path, "https://localhost:\(securePort)/secret"]), "GET /secret ")
        // Two requests on one kept-alive TLS connection.
        XCTAssertEqual(try curl(["--cacert", sekishoPEM.path, "https://localhost:\(securePort)/a", "https://localhost:\(securePort)/b"]), "GET /a GET /b ")
        // Not on the SSL list: tunnelled, so curl sees the origin's own certificate.
        // (-k because the origin's certificate names localhost, not 127.0.0.1.)
        XCTAssertEqual(try curl(["-k", "https://127.0.0.1:\(securePort)/t"]), "GET /t ")
        // An upgrade inside a decrypted connection is relayed raw (this used to crash the proxy).
        XCTAssertTrue(try curl(["--cacert", sekishoPEM.path, "-H", "Connection: Upgrade", "-H", "Upgrade: websocket",
                                "https://localhost:\(securePort)/ws"]).hasPrefix("GET /ws"))
        // CONNECT inside a decrypted connection is refused, not a crash.
        let nested = try curl(["--cacert", sekishoPEM.path, "-o", "/dev/null", "-w", "%{http_code}", "-X", "CONNECT", "https://localhost:\(securePort)/x"])
        XCTAssertTrue(["400", "405"].contains(nested), nested)
        // A client that half-closes after its request gets the response and then EOF, not a hang.
        let script = """
        import socket, sys
        s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
        s.sendall(("GET http://127.0.0.1:%s/half HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n" % sys.argv[2]).encode())
        s.shutdown(socket.SHUT_WR)
        data = b""
        while True:
            chunk = s.recv(65536)
            if not chunk: break
            data += chunk
        print(data.decode(errors="replace"))
        """
        let half = String(decoding: try run("/usr/bin/python3", ["-c", script, String(proxy.port), String(plainPort)]), as: UTF8.self)
        XCTAssertTrue(half.contains("GET /half"), half)
        // Blocked.
        XCTAssertTrue(try curl(["http://blocked.test/"]).contains("Blocked by Sekisho"))
        // The proxy serves its own CA.
        XCTAssertTrue(try curl(["http://sekisho.ca/ca.pem"]).contains("BEGIN CERTIFICATE"))

        settled { flows.withLockedValue { $0.values.map { "\($0.id) \($0.ended != nil) \($0.status ?? 0)" }.sorted() } }
        let all = flows.withLockedValue { Array($0.values) }
        let post = try XCTUnwrap(all.first { $0.path == "/plain?x=1" })
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(String(decoding: post.requestBody, as: UTF8.self), "ping")
        XCTAssertEqual(post.status, 200)
        XCTAssertEqual(post.responseHeader("X-Origin"), "sekisho-test")
        let secret = try XCTUnwrap(all.first { $0.path == "/secret" })
        XCTAssertEqual(secret.scheme, "https")
        XCTAssertEqual(String(decoding: secret.responseBody, as: UTF8.self), "GET /secret ")
        XCTAssertNotNil(secret.ended)
        XCTAssertTrue(all.contains { $0.kind == .tunnel && $0.host == "127.0.0.1" && $0.bytesDown > 0 })
        XCTAssertTrue(all.contains { $0.blocked && $0.host == "blocked.test" })
    }

    func testDecryptingAHostClosesItsOpenTunnels() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let origin = try startOrigin(group: group, tls: nil)
        defer { try? origin.close().wait() }
        let proxy = try ProxyServer(port: 0, ca: try CertificateAuthority()) { _ in }
        try proxy.start()
        defer { proxy.stop() }
        // A tunnel held open, as a browser keeps one; it must end once its host is decrypted.
        let script = """
        import socket, sys, time
        s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
        s.sendall(("CONNECT 127.0.0.1:%s HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n" % sys.argv[2]).encode())
        print(s.recv(100).decode().split("\\r\\n")[0], flush=True)
        start = time.time()
        while s.recv(100): pass
        print("closed after %.1f" % (time.time() - start), flush=True)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", script, String(proxy.port), String(origin.localAddress!.port!)]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        // Wait for the tunnel to be up (its 200), not for a fixed time: a slow machine starts python late, and a rule
        // set before the CONNECT arrives decrypts it from the start, leaving no tunnel to close.
        var head = Data()
        while !head.contains(UInt8(ascii: "\n")) {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            head += chunk
        }
        proxy.setRules(ProxyRules(sslProxying: ["127.0.0.1"]))
        p.waitUntilExit()
        let text = String(decoding: head + out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(text.contains("200 Connection Established"), text)
        XCTAssertTrue(text.contains("closed after"), text)
    }

    func testUntrustedUpstreamIsReported() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let secure = try startOrigin(group: group, tls: try CertificateAuthority().serverContext(for: "localhost"))
        defer { try? secure.close().wait() }
        let flows = NIOLockedValueBox<[Flow]>([])
        let ca = try CertificateAuthority()
        let proxy = try ProxyServer(port: 0, ca: ca, rules: ProxyRules(sslProxying: ["*"])) { f in flows.withLockedValue { $0.append(f) } }
        try proxy.start()
        defer { proxy.stop() }
        let pem = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pem")
        try ca.rootPEM.write(to: pem, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: pem) }
        let out = String(decoding: try run("/usr/bin/curl", ["-sS", "-x", "http://127.0.0.1:\(proxy.port)", "--cacert", pem.path,
                                                              "-w", "%{http_code}", "https://localhost:\(secure.localAddress!.port!)/"]), as: UTF8.self)
        XCTAssertTrue(out.hasSuffix("502"), out)
        eventually { flows.withLockedValue { $0 }.contains { ($0.error ?? "").contains("Upstream TLS failed") } }
        XCTAssertTrue(flows.withLockedValue { $0 }.contains { ($0.error ?? "").contains("Upstream TLS failed") })
    }

    // MARK: Helpers

    private func startOrigin(group: EventLoopGroup, tls: NIOSSLContext?) throws -> Channel {
        try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(EchoOrigin())
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}

/// Answers "METHOD /path body".
private final class EchoOrigin: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var line = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): line = "\(h.method.rawValue) \(h.uri) "
        case .body(let b): line += String(buffer: b)
        case .end:
            let headers = HTTPHeaders([("Content-Length", String(line.utf8.count)), ("X-Origin", "sekisho-test")])
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: line)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

extension XCTestCase {
    /// Waits until `condition` holds, up to `timeout`: flows are reported a moment after the client has its answer,
    /// and a fixed sleep is either slow or, on a busy CI machine, too short.
    func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { Thread.sleep(forTimeInterval: 0.02) }
    }

    /// Waits until `state` stops changing (three polls in a row, 0.3 s), up to `timeout`.
    func settled(timeout: TimeInterval = 5, _ state: () -> [String]) {
        let end = Date().addingTimeInterval(timeout)
        var last: [String]?, stable = 0
        while Date() < end {
            let now = state()
            if now == last, !now.isEmpty { stable += 1; if stable >= 3 { return } } else { stable = 0; last = now }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
