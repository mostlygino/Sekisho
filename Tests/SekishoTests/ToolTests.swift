import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import SekishoCore

final class ToolTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var origin: Channel!
    private var originPort: Int { origin.localAddress!.port! }
    private let flows = NIOLockedValueBox<[Int: Flow]>([:])
    private let apps = NIOLockedValueBox<[Int: ClientApp]>([:])  // by connection

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        origin = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Echo())
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    override func tearDownWithError() throws {
        try origin.close().wait()
        try group.syncShutdownGracefully()
    }

    private func proxy(_ rules: ProxyRules) throws -> ProxyServer {
        let server = try ProxyServer(port: 0, ca: try CertificateAuthority(), rules: rules) { [flows] f in
            flows.withLockedValue { $0[f.id] = f }
        }
        server.onClientApp = { [apps] connection, app in apps.withLockedValue { $0[connection] = app } }
        try server.start()
        return server
    }

    private func curlDirect(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-sS", "--max-time", "10"] + args
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func curl(_ proxy: ProxyServer, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-sS", "--max-time", "10", "-x", "http://127.0.0.1:\(proxy.port)"] + args
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func settle() -> [Flow] {
        settled { flows.withLockedValue { $0.values.map { "\($0.id) \($0.ended != nil) \($0.status ?? 0) \($0.interventions.count)" }.sorted() } }
        return flows.withLockedValue { $0.values.sorted { $0.id < $1.id } }
    }

    func testMatching() {
        XCTAssertTrue(ToolMatch.url("https://api.example.com/v1/users?id=1", "api.example.com"))
        XCTAssertTrue(ToolMatch.url("https://api.example.com/v1/users", "https://api.example.com/v1/*"))
        XCTAssertFalse(ToolMatch.url("http://api.example.com/v1/users", "https://api.example.com/*"))
        XCTAssertTrue(ToolMatch.url("http://x.test/a", "*.test/a"))
        XCTAssertEqual(Flow.wireTarget("/f?x=a|b c%20d"), "/f?x=a%7Cb%20c%20d")
        XCTAssertTrue(ToolMatch.url("http://127.0.0.1:8080/a", "127.0.0.1"))
        XCTAssertFalse(ToolMatch.url("http://127.0.0.10/a", "127.0.0.1"))
        XCTAssertFalse(ToolMatch.url("https://evil.test/r?u=http://api.example.com/x", "api.example.com"))
        XCTAssertTrue(ToolMatch.url("https://api.example.com:8443/v1/x", "https://api.example.com:8443/v1/*"))
        XCTAssertFalse(ToolMatch.url("https://api.example.com:9443/v1/x", "https://api.example.com:8443/v1/*"))
    }

    func testMapLocal() throws {
        let server = try proxy(ProxyRules(mapLocal: [MapLocalRule(pattern: "http://127.0.0.1:\(originPort)/local*", status: 201, body: "{\"local\":true}")]))
        defer { server.stop() }
        XCTAssertEqual(try curl(server, ["http://127.0.0.1:\(originPort)/local/x"]), "{\"local\":true}")
        XCTAssertEqual(try curl(server, ["http://127.0.0.1:\(originPort)/other"]), "GET /other ")
        let local = try XCTUnwrap(settle().first { $0.path == "/local/x" })
        XCTAssertEqual(local.status, 201)
        XCTAssertTrue(local.interventions.contains(.mapLocal))
    }

    func testMapRemote() throws {
        let server = try proxy(ProxyRules(mapRemote: [MapRemoteRule(pattern: "http://nowhere.invalid/*", destination: "http://127.0.0.1:\(originPort)/moved")]))
        defer { server.stop() }
        XCTAssertEqual(try curl(server, ["http://nowhere.invalid/old?q=1"]), "GET /moved?q=1 ")
        let f = try XCTUnwrap(settle().first)
        XCTAssertEqual(f.mappedFrom, "http://nowhere.invalid/old?q=1")
        XCTAssertEqual(f.requestHeader("Host"), "127.0.0.1:\(originPort)")
        XCTAssertTrue(f.interventions.contains(.mapRemote))
    }

    func testBreakpointsEditRequestAndResponse() throws {
        let server = try proxy(ProxyRules(breakpoints: [BreakpointRule(pattern: "127.0.0.1", request: true, response: true)]))
        defer { server.stop() }
        server.breakpointHandler = { stage, flow in
            var f = flow
            switch stage {
            case .request:
                f.path = "/edited"
                f.setRequestBodyText("changed")
                f.method = "PUT"
            case .response:
                XCTAssertEqual(String(decoding: f.responseBody, as: UTF8.self), "PUT /edited changed")
                f.setResponseBodyText("from the breakpoint")
                f.status = 299
            }
            return f
        }
        let out = try curl(server, ["-w", " %{http_code}", "-d", "original", "http://127.0.0.1:\(originPort)/start"])
        XCTAssertEqual(out, "from the breakpoint 299")
        let f = try XCTUnwrap(settle().first)
        XCTAssertTrue(f.interventions.isSuperset(of: [.hold, .edited]))
        XCTAssertNotNil(f.ended)

        server.breakpointHandler = { _, _ in nil }
        XCTAssertTrue(try curl(server, ["http://127.0.0.1:\(originPort)/abort"]).contains("Aborted"))
        XCTAssertTrue(settle().contains { $0.interventions.contains(.aborted) })
    }

    func testReplayAndClientApp() throws {
        let server = try proxy(ProxyRules())
        defer { server.stop() }
        XCTAssertEqual(try curl(server, ["http://127.0.0.1:\(originPort)/first"]), "GET /first ")
        let first = try XCTUnwrap(settle().first)
        var copy = first
        copy.path = "/again"
        let id = server.replay(copy)
        let replayed = try XCTUnwrap(settle().first { $0.id == id })
        XCTAssertEqual(String(decoding: replayed.responseBody, as: UTF8.self), "GET /again ")
        XCTAssertTrue(replayed.interventions.contains(.replay))
        // The connection came from curl.
        let connection = try XCTUnwrap(first.connection)
        XCTAssertEqual(apps.withLockedValue { $0[connection]?.name }, "curl")
    }

    func testAllowListNoCachingAndDNSSpoofing() throws {
        var rules = ProxyRules()
        rules.allowList = ["spoof.test"]
        rules.noCaching = true
        rules.dnsSpoofing = [DNSRule(host: "spoof.test", address: "127.0.0.1")]
        rules.sslProxying = ["*"]
        rules.sslExclude = ["bank.test"]
        XCTAssertFalse(rules.intercepts("bank.test"))
        XCTAssertFalse(rules.intercepts("other.test"), "not on the Allow List, so not decrypted either")
        let server = try proxy(rules)
        defer { server.stop() }
        // Not on the Allow List: answered, not recorded.
        XCTAssertEqual(try curl(server, ["http://127.0.0.1:\(originPort)/quiet"]), "GET /quiet ")
        // spoof.test resolves to 127.0.0.1 through DNS Spoofing, and keeps its name in Host.
        XCTAssertEqual(try curl(server, ["-H", "If-None-Match: abc", "http://spoof.test:\(originPort)/loud"]), "GET /loud ")
        let all = settle()
        XCTAssertEqual(all.count, 1)
        let f = try XCTUnwrap(all.first)
        XCTAssertEqual(f.host, "spoof.test")
        XCTAssertNil(f.requestHeader("If-None-Match"))
        XCTAssertEqual(f.responseHeader("Cache-Control"), "no-store, no-cache, must-revalidate")
        XCTAssertTrue(f.interventions.contains(.spoofed))
    }

    func testMapLocalFolderAndThrottle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("v1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"from":"folder"}"#.utf8).write(to: dir.appendingPathComponent("v1/user.json"))
        var local = MapLocalRule(pattern: "http://127.0.0.1:\(originPort)/static/*")
        local.directory = dir.path
        var rules = ProxyRules(mapLocal: [local])
        rules.throttles = [ThrottleRule(pattern: "http://127.0.0.1:\(originPort)/slow*", latencyMs: 400)]
        let server = try proxy(rules)
        defer { server.stop() }
        XCTAssertEqual(try curl(server, ["http://127.0.0.1:\(originPort)/static/v1/user.json"]), #"{"from":"folder"}"#)
        XCTAssertEqual(try curl(server, ["http://127.0.0.1:\(originPort)/static/missing.json"]), "GET /static/missing.json ")
        XCTAssertTrue(try curl(server, ["http://127.0.0.1:\(originPort)/static/../../etc/passwd", "--path-as-is"]).hasPrefix("GET "),
                      "never outside the folder")
        let start = Date()
        XCTAssertEqual(try curl(server, ["http://127.0.0.1:\(originPort)/slow"]), "GET /slow ")
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.39)
        let flows = settle()
        XCTAssertEqual(flows.first { $0.path == "/static/v1/user.json" }?.responseHeader("Content-Type"), "application/json")
        XCTAssertTrue(flows.first { $0.path == "/slow" }?.interventions.contains(.throttled) == true)
    }

    func testScripting() throws {
        var rule = ScriptRule(pattern: "127.0.0.1", name: "Test")
        rule.code = """
        function onRequest(context, url, request) {
          request.path = "/scripted";
          request.queries["who"] = "sekisho";
          request.headers["X-Added"] = "1";
          context.sharedState.count = (context.sharedState.count || 0) + 1;
          console.log("request", context.sharedState.count);
          return request;
        }
        function onResponse(context, url, request, response) {
          response.statusCode = 201;
          response.body = response.body + "+changed";
          return response;
        }
        """
        let server = try proxy(ProxyRules())
        defer { server.stop() }
        let logs = NIOLockedValueBox<[String]>([])
        server.scripts.log = { line in logs.withLockedValue { $0.append(line) } }
        var rules = ProxyRules()
        rules.scripts = [rule]
        server.setRules(rules)
        let out = try curl(server, ["-w", " %{http_code}", "http://127.0.0.1:\(originPort)/original"])
        XCTAssertEqual(out, "GET /scripted?who=sekisho +changed 201")
        let f = try XCTUnwrap(settle().first)
        XCTAssertEqual(f.requestHeader("X-Added"), "1")
        XCTAssertTrue(f.interventions.contains(.script))
        XCTAssertTrue(logs.withLockedValue { $0 }.contains("Test: request 1"))
    }

    func testReverseProxy() throws {
        let local = Int.random(in: 41_000...48_000)
        var rules = ProxyRules()
        rules.reverseProxies = [ReverseProxyRule(localPort: local, remoteHost: "127.0.0.1", remotePort: originPort, tls: false)]
        let server = try proxy(rules)
        defer { server.stop() }
        XCTAssertNil(server.reverseErrors.values.first)
        XCTAssertEqual(try curlDirect(["http://127.0.0.1:\(local)/through"]), "GET /through ")
        let f = try XCTUnwrap(settle().first)
        XCTAssertEqual(f.requestHeader("Host"), "127.0.0.1:\(originPort)")
    }

    func testUpstreamProxyChain() throws {
        // B is the "company proxy"; A sends everything through it.
        let seenByB = NIOLockedValueBox<[Flow]>([])
        let b = try ProxyServer(port: 0, ca: try CertificateAuthority()) { f in seenByB.withLockedValue { $0.append(f) } }
        try b.start()
        defer { b.stop() }
        var rules = ProxyRules()
        var upstream = UpstreamProxy(host: "127.0.0.1", port: b.port)
        upstream.bypass = []
        rules.upstreamProxy = upstream
        let a = try proxy(rules)
        defer { a.stop() }
        XCTAssertEqual(try curl(a, ["http://127.0.0.1:\(originPort)/chained"]), "GET /chained ")
        // A tunnel through A becomes a CONNECT at B.
        XCTAssertEqual(try curl(a, ["-p", "http://127.0.0.1:\(originPort)/tunnelled"]), "GET /tunnelled ")
        eventually { seenByB.withLockedValue { b in b.contains { $0.path == "/chained" } && b.contains { $0.kind == .tunnel && $0.port == originPort } } }
        let atB = seenByB.withLockedValue { $0 }
        XCTAssertTrue(atB.contains { $0.path == "/chained" }, "plain HTTP reached B in absolute form")
        XCTAssertTrue(atB.contains { $0.kind == .tunnel && $0.port == originPort }, "the tunnel was a CONNECT at B")
    }

    func testLocalNetworkCheck() throws {
        XCTAssertTrue(ProxyHandler.isLocalNetwork(try SocketAddress(ipAddress: "192.168.1.20", port: 1)))
        XCTAssertTrue(ProxyHandler.isLocalNetwork(try SocketAddress(ipAddress: "10.0.0.5", port: 1)))
        XCTAssertTrue(ProxyHandler.isLocalNetwork(try SocketAddress(ipAddress: "::1", port: 1)))
        XCTAssertFalse(ProxyHandler.isLocalNetwork(try SocketAddress(ipAddress: "8.8.8.8", port: 1)))
        XCTAssertFalse(ProxyHandler.isLocalNetwork(try SocketAddress(ipAddress: "172.32.0.1", port: 1)))
    }

    func testCategoriesAndForms() {
        var f = Flow(id: 1)
        f.responseHeaders = [.init("Content-Type", "application/json; charset=utf-8")]
        XCTAssertEqual(f.category, .json)
        f.responseHeaders = [.init("Content-Type", "image/png")]
        XCTAssertEqual(f.category, .media)
        f.requestHeaders = [.init("Content-Type", "application/json")]
        f.requestBody = Data(#"{"query":"query GetUser($id: ID!) { user(id: $id) { name } }"}"#.utf8)
        XCTAssertEqual(f.graphQLOperation, "GetUser")
        XCTAssertEqual(f.category, .graphql)
        XCTAssertEqual(FormParser.urlEncoded(Data("a=1&b=two+words&c=%26".utf8)).map { $0.1 }, ["1", "two words", "&"])
        let body = "--XyZ\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nHello\r\n--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nfile body\r\n--XyZ--\r\n"
        let parts = FormParser.multipart(Data(body.utf8), contentType: "multipart/form-data; boundary=XyZ")
        XCTAssertEqual(parts.map(\.name), ["title", "file"])
        XCTAssertEqual(parts.last?.filename, "a.txt")
        XCTAssertEqual(String(decoding: parts[0].body, as: UTF8.self), "Hello")
    }

    func testExports() throws {
        var f = Flow(id: 1)
        f.scheme = "https"; f.host = "api.example.com"; f.port = 443; f.method = "POST"; f.path = "/v1?a=b"
        f.requestHeaders = [.init("Content-Type", "application/json"), .init("X-Quote", "it's")]
        f.requestBody = Data("{\"a\":1}".utf8)
        f.status = 200; f.responseHeaders = [.init("Content-Type", "application/json")]; f.responseBody = Data("{}".utf8)
        f.ended = f.started.addingTimeInterval(0.25)
        let curl = Export.curl(f)
        XCTAssertTrue(curl.contains("'https://api.example.com/v1?a=b'"))
        XCTAssertTrue(curl.contains("'X-Quote: it'\\''s'"))
        XCTAssertTrue(curl.contains("--data-raw '{\"a\":1}'"))
        XCTAssertTrue(curl.contains("--globoff"))
        let har = try JSONSerialization.jsonObject(with: try Export.har([f])) as? [String: Any]
        let entries = (har?["log"] as? [String: Any])?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual((entries?.first?["request"] as? [String: Any])?["method"] as? String, "POST")
    }
}

/// Answers "METHOD /path body".
private final class Echo: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var line = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): line = "\(h.method.rawValue) \(h.uri) "
        case .body(let b): line += String(buffer: b)
        case .end:
            let headers = HTTPHeaders([("Content-Length", String(line.utf8.count))])
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: line)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
