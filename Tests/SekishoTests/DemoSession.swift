import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import XCTest
@testable import SekishoCore

/// Records `docs/demo/Sekisho demo.sekisho`: a believable session for screenshots and review, made by the real proxy
/// against a local fixture server, then given real-looking hosts. Only runs with SEKISHO_MAKE_DEMO=1.
///
///   SEKISHO_MAKE_DEMO=1 swift test --filter DemoSession
final class DemoSession: XCTestCase {
    func testMakeDemoSession() throws {
        guard ProcessInfo.processInfo.environment["SEKISHO_MAKE_DEMO"] == "1" else { throw XCTSkip("set SEKISHO_MAKE_DEMO=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let avatar = try Data(contentsOf: root.appendingPathComponent("Resources/mostlygino.png"))
        let origin = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { ch, _ in ch.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                                         upgradePipelineHandler: { ch, _ in ch.pipeline.addHandler(Echo()) })
                // After the upgrade the shop steps aside for the WebSocket frames.
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { ctx in
                    ctx.pipeline.removeHandler(name: "shop", promise: nil)
                }))
                .flatMap { channel.pipeline.addHandler(Shop(avatar: avatar), name: "shop") }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? origin.close().wait() }
        let port = origin.localAddress!.port!
        let base = "http://127.0.0.1:\(port)"

        let flows = NIOLockedValueBox<[Int: Flow]>([:])
        var rules = ProxyRules()
        var flag = MapLocalRule(pattern: "\(base)/v2/flags*", body: "{\n  \"newCheckout\": true,\n  \"darkMode\": \"auto\"\n}")
        flag.contentType = "application/json"
        rules.mapLocal = [flag]
        rules.blocked = ["ads.example.net"]
        rules.throttles = [ThrottleRule(pattern: "\(base)/v2/recommendations*", latencyMs: 300, downKbps: 780, upKbps: 330)]
        var script = ScriptRule(pattern: "\(base)/v2/products/42", name: "Add debug header")
        script.code = "function onRequest(c, u, r) { r.headers[\"X-Debug\"] = \"sekisho\"; return r; }"
        script.response = false
        rules.scripts = [script]
        rules.breakpoints = [BreakpointRule(pattern: "\(base)/v2/cart", request: false, response: true)]
        let proxy = try ProxyServer(port: 0, ca: try CertificateAuthority(), rules: rules) { f in flows.withLockedValue { $0[f.id] = f } }
        proxy.breakpointHandler = { _, flow in
            var f = flow
            f.setResponseBodyText("{\n  \"items\": [],\n  \"note\": \"edited at a breakpoint\"\n}")
            f.status = 200
            return f
        }
        try proxy.start()
        defer { proxy.stop() }

        func curl(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "-o", "/dev/null", "--max-time", "10", "-x", "http://127.0.0.1:\(proxy.port)",
                           "-H", "User-Agent: Tegata/3.4 (iPhone; iOS 26.0)", "-H", "Accept-Language: nl-NL,en;q=0.8"] + args
            try? p.run(); p.waitUntilExit()
        }
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1XzgyMTEiLCJuYW1lIjoiQWxleCBWaXNzZXIiLCJleHAiOjE5MDAwMDAwMDB9.c2lnbmF0dXJl"
        curl(["-H", "Accept: text/html", "\(base)/"])
        curl(["\(base)/images/avatar.png"])
        curl(["-H", "Accept: application/json", "-H", "Authorization: Bearer \(token)", "--compressed", "\(base)/v2/products?category=coffee&sort=price"])
        curl(["-H", "Authorization: Bearer \(token)", "\(base)/v2/products/42"])
        curl(["-H", "Content-Type: application/json", "-H", "Authorization: Bearer \(token)",
              "--data-raw", #"{"operationName":"CartQuery","query":"query CartQuery($id: ID!) { cart(id: $id) { items { sku quantity } total } }","variables":{"id":"c_77"}}"#,
              "\(base)/graphql"])
        curl(["\(base)/v2/flags"])
        curl(["-d", "email=alex%40example.com&password=hunter2&remember=on", "\(base)/login"])
        curl(["-H", "Cookie: session=7f3a9c", "\(base)/account"])
        curl(["-F", "title=Weekend beans", "-F", "photo=@\(root.path)/Resources/mostlygino.png;type=image/png", "\(base)/upload"])
        curl(["\(base)/v2/cart"])
        curl(["\(base)/v2/orders"])
        curl(["\(base)/v2/recommendations"])
        curl(["http://ads.example.net/pixel.gif"])
        curl(["-X", "DELETE", "-H", "Authorization: Bearer \(token)", "\(base)/v2/sessions/old"])
        curl(["\(base)/health"])
        // A WebSocket conversation: upgrade, three messages, close.
        let ws = Process()
        ws.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        ws.arguments = ["-c", """
        import socket, os, sys, time
        s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
        s.sendall(("GET http://127.0.0.1:%s/live HTTP/1.1\\r\\nHost: x\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n"
                   "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\\r\\nSec-WebSocket-Version: 13\\r\\n\\r\\n" % sys.argv[2]).encode())
        s.recv(4096)
        def frame(op, data):
            mask = os.urandom(4)
            return bytes([0x80 | op, 0x80 | len(data)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        for m in [b'{"type":"subscribe","channel":"orders"}', b'{"type":"ping","t":1}', b'{"type":"cart.update","sku":"BEANS-1KG","qty":2}']:
            s.sendall(frame(1, m)); time.sleep(0.15); s.recv(4096)
        s.sendall(frame(8, b'\\x03\\xe8')); time.sleep(0.2); s.close()
        """, String(proxy.port), String(port)]
        try ws.run(); ws.waitUntilExit()
        Thread.sleep(forTimeInterval: 1)

        // Real-looking hosts, ports and apps; a few encrypted tunnels from other apps for the sidebar.
        var out = flows.withLockedValue { $0.values.sorted { $0.id < $1.id } }
        for i in out.indices {
            var f = out[i]
            let path = f.path
            let host = path.hasPrefix("/images") ? "cdn.example.com" : path.hasPrefix("/v2") || path.hasPrefix("/graphql") ? "api.example.com"
                : path.hasPrefix("/live") ? "realtime.example.com" : f.host == "ads.example.net" ? f.host : "www.example.com"
            if f.port == port, path == "/health" {
                // A box on the LAN by address, plain HTTP (192.0.2.x is documentation space).
                f.host = "192.0.2.44"
                f.port = 8080
            } else if f.port == port {
                f.host = host
                f.port = 443
                f.scheme = "https"
            }
            f.requestHeaders = f.requestHeaders.map { $0.name.lowercased() == "host" ? Flow.Header("Host", f.authority) : $0 }
                .filter { $0.name.lowercased() != "proxy-connection" }
            if f.mappedFrom != nil { f.mappedFrom = nil }
            f.connection = path == "/health" ? 5 : host == "www.example.com" || host == "cdn.example.com" || host == "ads.example.net" ? 1 : 2
            out[i] = f
        }
        var next = (out.map(\.id).max() ?? 0) + 1
        let start = out.first?.started ?? Date()
        for (host, app, up, down) in [("mail.example.org", 3, 4_812, 18_430), ("chat.example.org", 4, 2_210, 96_550), ("push.example.net", 4, 880, 12_040),
                                      ("bank.example.org", 1, 3_102, 41_877)] {
            var t = Flow(id: next); next += 1
            t.kind = .tunnel; t.method = "CONNECT"; t.scheme = "https"; t.host = host; t.port = 443; t.path = ""
            t.started = start.addingTimeInterval(Double(next) * 0.37); t.ended = t.started.addingTimeInterval(1.8 + Double(next % 3))
            t.bytesUp = up; t.bytesDown = down; t.connection = app
            out.append(t)
        }
        let apps: [Int: ClientApp] = [
            1: ClientApp(pid: 812, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", bundlePath: "/Applications/Safari.app", name: "Safari"),
            2: ClientApp(pid: 2231, executablePath: "/System/Applications/App Store.app/Contents/MacOS/App Store",
                         bundlePath: "/System/Applications/App Store.app", name: "App Store"),
            3: ClientApp(pid: 401, executablePath: "/System/Applications/Mail.app/Contents/MacOS/Mail", bundlePath: "/System/Applications/Mail.app", name: "Mail"),
            4: ClientApp(pid: 1502, executablePath: "/System/Applications/Messages.app/Contents/MacOS/Messages", bundlePath: "/System/Applications/Messages.app", name: "Messages"),
            5: ClientApp(pid: 977, executablePath: "/usr/bin/curl", bundlePath: nil, name: "curl"),
        ]
        out.sort { $0.started < $1.started }
        for i in out.indices { out[i].id = i + 1 }
        struct Mark: Codable { var color: String?; var strike = false; var comment = "" }
        var marks: [Int: Mark] = [:]
        if let cart = out.first(where: { $0.path == "/v2/cart" }) { marks[cart.id] = Mark(color: "yellow", comment: "Empty cart for the checkout test") }
        if let err = out.first(where: { $0.status == 500 }) { marks[err.id] = Mark(color: "red", comment: "Ticket TEG-418") }
        let file = SessionFile(flows: out, marks: try JSONEncoder().encode(marks), apps: apps)
        let url = root.appendingPathComponent("docs/demo/Sekisho demo.sekisho")
        try file.encoded().write(to: url)
        XCTAssertGreaterThan(out.count, 15)
        print("Wrote \(out.count) flows to \(url.path)")
    }
}

/// A small shop's API, website and CDN, with believable latencies.
private final class Shop: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let avatar: Data
    private var head: HTTPRequestHead?
    init(avatar: Data) { self.avatar = avatar }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): head = h
        case .body: break
        case .end:
            guard let h = head else { return }
            let path = h.uri.split(separator: "?").first.map(String.init) ?? h.uri
            var status = HTTPResponseStatus.ok, type = "application/json; charset=utf-8", body = Data(), extra: [(String, String)] = []
            var delay = 60
            switch (h.method, path) {
            case (.GET, "/"):
                type = "text/html; charset=utf-8"; delay = 140
                body = Data("""
                <!doctype html><html><head><title>Tegata Coffee</title></head><body style="font-family: -apple-system; margin: 40px">
                <h1>Tegata Coffee</h1><p>Single-origin beans, roasted in Naaldwijk.</p><ul><li>Kenya AA</li><li>Ethiopia Guji</li></ul></body></html>
                """.utf8)
            case (.GET, "/images/avatar.png"): type = "image/png"; body = avatar; delay = 90; extra = [("Cache-Control", "public, max-age=31536000")]
            case (.GET, "/v2/products"):
                delay = 180
                body = Data(#"{"category":"coffee","page":1,"total":3,"items":[{"id":42,"sku":"BEANS-1KG","name":"Kenya AA","price":24.5,"inStock":true,"roast":"light"},{"id":43,"sku":"BEANS-500","name":"Ethiopia Guji","price":14.0,"inStock":true,"roast":"medium"},{"id":51,"sku":"DRIP-KIT","name":"Pour-over kit","price":39.95,"inStock":false,"roast":null}]}"#.utf8)
                extra = [("ETag", "\"p-9c1f\""), ("X-Request-Id", "req_01HF8Z3K")]
            case (.GET, "/v2/products/42"):
                delay = 95
                body = Data(#"{"id":42,"sku":"BEANS-1KG","name":"Kenya AA","price":24.5,"origin":{"country":"Kenya","region":"Nyeri","altitude":1800},"notes":["blackcurrant","tomato","brown sugar"],"inStock":true}"#.utf8)
            case (.POST, "/graphql"):
                delay = 210
                body = Data(#"{"data":{"cart":{"items":[{"sku":"BEANS-1KG","quantity":2},{"sku":"DRIP-KIT","quantity":1}],"total":88.95}}}"#.utf8)
            case (.POST, "/login"):
                status = .found; delay = 260; type = "text/plain"
                extra = [("Location", "/account"), ("Set-Cookie", "session=7f3a9c; Path=/; HttpOnly; Secure; SameSite=Lax"), ("Set-Cookie", "remember=1; Max-Age=2592000; Path=/")]
            case (.GET, "/account"):
                delay = 120
                body = Data(#"{"id":"u_8211","name":"Alex Visser","email":"alex@example.com","orders":12,"member":"gold"}"#.utf8)
            case (.POST, "/upload"): status = .created; delay = 420; body = Data(#"{"id":"img_5521","url":"https://cdn.example.com/u/img_5521.png"}"#.utf8)
            case (.GET, "/v2/cart"):
                status = .unauthorized; delay = 70
                body = Data(#"{"error":"unauthorized","message":"A token is required for this cart"}"#.utf8)
            case (.GET, "/v2/orders"):
                status = .notFound; delay = 55
                body = Data(#"{"error":"not_found","message":"No orders for this account"}"#.utf8)
            case (.GET, "/v2/recommendations"):
                status = .internalServerError; type = "text/html; charset=utf-8"; delay = 640
                body = Data("<html><body><h1>500 Internal Server Error</h1><p>upstream recommender timed out</p></body></html>".utf8)
            case (.DELETE, _): status = .noContent; delay = 80
            case (.GET, "/health"): delay = 12; body = Data(#"{"status":"ok","uptime":86412,"version":"2.3.1"}"#.utf8)
            default: status = .notFound; body = Data(#"{"error":"not_found"}"#.utf8)
            }
            var headers = HTTPHeaders([("Server", "tegata-edge/2.3"), ("Date", "Mon, 19 Oct 2026 14:32:08 GMT")])
            if !body.isEmpty || status != .noContent { headers.add(name: "Content-Type", value: type) }
            headers.add(name: "Content-Length", value: String(body.count))
            for (n, v) in extra { headers.add(name: n, value: v) }
            let response = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            let payload = body
            context.eventLoop.scheduleTask(in: .milliseconds(Int64(delay))) {
                context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                if !payload.isEmpty { context.write(self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: payload)))), promise: nil) }
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

/// Answers each WebSocket text message with an acknowledgement.
private final class Echo: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
            let reply = text.contains("subscribe") ? #"{"type":"subscribed","channel":"orders"}"#
                : text.contains("ping") ? #"{"type":"pong","t":1}"# : #"{"type":"cart.updated","total":88.95}"#
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: reply))), promise: nil)
        case .connectionClose:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData))).whenComplete { _ in
                context.close(promise: nil)
            }
        default: break
        }
    }
}
