import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS

/// Which hosts get decrypted, which get refused, and the tool rules. Host patterns: `example.com`, `*.example.com`, `*`.
public struct ProxyRules: Sendable, Equatable, Codable {
    public var sslProxying: [String] = []
    /// Hosts never decrypted, even when the SSL Proxying list matches them.
    public var sslExclude: [String] = []
    public var blocked: [String] = []
    /// Blocked requests are refused and also left out of the list.
    public var hideBlocked = false
    /// When not empty, only these hosts are recorded (and decrypted); everything else passes through unseen.
    public var allowList: [String] = []
    /// Strip conditional request headers and force no-store on responses, so every request reaches the server.
    public var noCaching = false
    public var breakpoints: [BreakpointRule] = []
    public var mapLocal: [MapLocalRule] = []
    public var mapRemote: [MapRemoteRule] = []
    public var dnsSpoofing: [DNSRule] = []
    public var throttles: [ThrottleRule] = []
    public var scripts: [ScriptRule] = []
    public var reverseProxies: [ReverseProxyRule] = []
    public var upstreamProxy: UpstreamProxy?

    public init(sslProxying: [String] = [], blocked: [String] = [], breakpoints: [BreakpointRule] = [],
                mapLocal: [MapLocalRule] = [], mapRemote: [MapRemoteRule] = []) {
        self.sslProxying = sslProxying
        self.blocked = blocked
        self.breakpoints = breakpoints
        self.mapLocal = mapLocal
        self.mapRemote = mapRemote
    }

    /// Tolerates saved rules from older versions that lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sslProxying = try c.decodeIfPresent([String].self, forKey: .sslProxying) ?? []
        sslExclude = try c.decodeIfPresent([String].self, forKey: .sslExclude) ?? []
        blocked = try c.decodeIfPresent([String].self, forKey: .blocked) ?? []
        hideBlocked = try c.decodeIfPresent(Bool.self, forKey: .hideBlocked) ?? false
        allowList = try c.decodeIfPresent([String].self, forKey: .allowList) ?? []
        noCaching = try c.decodeIfPresent(Bool.self, forKey: .noCaching) ?? false
        breakpoints = try c.decodeIfPresent([BreakpointRule].self, forKey: .breakpoints) ?? []
        mapLocal = try c.decodeIfPresent([MapLocalRule].self, forKey: .mapLocal) ?? []
        mapRemote = try c.decodeIfPresent([MapRemoteRule].self, forKey: .mapRemote) ?? []
        dnsSpoofing = try c.decodeIfPresent([DNSRule].self, forKey: .dnsSpoofing) ?? []
        throttles = try c.decodeIfPresent([ThrottleRule].self, forKey: .throttles) ?? []
        scripts = try c.decodeIfPresent([ScriptRule].self, forKey: .scripts) ?? []
        reverseProxies = try c.decodeIfPresent([ReverseProxyRule].self, forKey: .reverseProxies) ?? []
        upstreamProxy = try c.decodeIfPresent(UpstreamProxy.self, forKey: .upstreamProxy)
    }

    public func intercepts(_ host: String) -> Bool {
        sslProxying.contains { Self.matches(host, $0) } && !sslExclude.contains { Self.matches(host, $0) } && records(host)
    }
    public func blocks(_ host: String) -> Bool { blocked.contains { Self.matches(host, $0) } }
    public func records(_ host: String) -> Bool { allowList.isEmpty || allowList.contains { Self.matches(host, $0) } }
    /// The address DNS Spoofing sends this host to, if any.
    public func spoofedAddress(_ host: String) -> String? {
        dnsSpoofing.first { $0.enabled && Self.matches(host, $0.host) && !$0.address.isEmpty }?.address
    }
    func throttle(for flow: Flow) -> ThrottleRule? { throttles.first { $0.enabled && ToolMatch.url(flow.url, $0.pattern) } }
    func script(for flow: Flow) -> ScriptRule? { scripts.first { $0.enabled && ToolMatch.url(flow.url, $0.pattern) } }

    public static func matches(_ host: String, _ pattern: String) -> Bool {
        let host = host.lowercased(), pattern = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            let base = pattern.dropFirst(2)
            return host == base || host.hasSuffix("." + base)
        }
        return host == pattern
    }
}

public enum BreakpointStage: String, Sendable { case request, response }

/// The HTTP(S) debugging proxy. Listens on loopback only; every exchange is reported through `onFlow`,
/// once when it starts and again as it progresses (same `id`).
public final class ProxyServer: @unchecked Sendable {
    /// The listening port; pass 0 to `init` to let the system pick one (read it after `start`).
    public private(set) var port: Int
    public let ca: CertificateAuthority
    let rules: NIOLockedValueBox<ProxyRules>
    let onFlow: @Sendable (Flow) -> Void
    let upstreamTLS: NIOSSLContext
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private let ids = NIOLockedValueBox(0)

    /// - Parameter upstreamTLS: how Sekisho checks the real servers. Defaults to the system trust store,
    ///   so an untrusted upstream is reported, not hidden behind Sekisho's own certificate.
    public init(port: Int = 9090, ca: CertificateAuthority, rules: ProxyRules = .init(),
                upstreamTLS: TLSConfiguration = .makeClientConfiguration(),
                onFlow: @escaping @Sendable (Flow) -> Void) throws {
        self.port = port
        self.ca = ca
        self.rules = NIOLockedValueBox(rules)
        self.onFlow = onFlow
        var tls = upstreamTLS
        tls.applicationProtocols = ["http/1.1"]
        tls.minimumTLSVersion = .tlsv12
        self.upstreamTLS = try NIOSSLContext(configuration: tls)
        self.lookup = ClientLookup(proxyPort: { [weak self] in self?.port ?? 0 },
                                   found: { [weak self] connection, app in self?.onClientApp?(connection, app) })
    }

    /// Changes the rules. A host that has just been put on the SSL Proxying list gets its open tunnels closed,
    /// so the app reconnects and its next request is decrypted, without a reload.
    public func setRules(_ new: ProxyRules) {
        let old = rules.withLockedValue { r -> ProxyRules in defer { r = new }; return r }
        if old.reverseProxies != new.reverseProxies { syncReverseProxies() }
        let doomed = tunnels.withLockedValue { open -> [Channel] in
            var out: [Channel] = []
            for (host, channels) in open where new.intercepts(host) || new.blocks(host) {
                out += channels.values
                open[host] = nil
            }
            return out
        }
        for channel in doomed { channel.close(promise: nil) }
    }

    /// Open CONNECT tunnels (client side) by host.
    private let tunnels = NIOLockedValueBox<[String: [ObjectIdentifier: Channel]]>([:])

    func trackTunnel(host: String, client: Channel) {
        let key = host.lowercased(), id = ObjectIdentifier(client)
        tunnels.withLockedValue { $0[key, default: [:]][id] = client }
        client.closeFuture.whenComplete { [weak self] _ in
            self?.tunnels.withLockedValue { open in
                open[key]?[id] = nil
                if open[key]?.isEmpty == true { open[key] = nil }
            }
        }
    }

    /// How long to wait for a server to accept a connection (curl waits 75 s; browsers about 30 s).
    static let connectTimeout = TimeAmount.seconds(30)

    func nextID() -> Int { ids.withLockedValue { $0 += 1; return $0 } }

    /// Records a flow unless the Allow List leaves its host out, or it is blocked and blocked requests are hidden.
    func emit(_ f: Flow) {
        let r = rules.withLockedValue { $0 }
        guard r.records(f.host), !(f.blocked && r.hideBlocked) else { return }
        onFlow(f)
    }

    public let scripts = ScriptRunner()

    private let clientAppBox = NIOLockedValueBox<(@Sendable (Int, ClientApp) -> Void)?>(nil)
    private let connections = NIOLockedValueBox(0)
    func nextConnection() -> Int { connections.withLockedValue { $0 += 1; return $0 } }
    /// Called (off the main thread) with a connection id when the app behind that connection is known.
    /// Flows carry `connection`.
    public var onClientApp: (@Sendable (Int, ClientApp) -> Void)? {
        get { clientAppBox.withLockedValue { $0 } }
        set { clientAppBox.withLockedValue { $0 = newValue } }
    }
    private(set) var lookup: ClientLookup!

    private let breakpointBox = NIOLockedValueBox<(@Sendable (BreakpointStage, Flow) async -> Flow?)?>(nil)
    /// Called when a breakpoint rule matches. Return the flow to continue (edited or not), or nil to abort.
    public var breakpointHandler: (@Sendable (BreakpointStage, Flow) async -> Flow?)? {
        get { breakpointBox.withLockedValue { $0 } }
        set { breakpointBox.withLockedValue { $0 = newValue } }
    }

    /// Listen on every interface so phones and other machines can use Sekisho. Off by default; only clients on
    /// loopback and private ranges (10/8, 172.16/12, 192.168/16, 169.254/16, fc00::/7, fe80::/10) are served.
    public var allowLAN = false

    public func start() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: min(4, System.coreCount))
        self.group = group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try ProxyHandler.addHTTPHandlers(channel.pipeline.syncOperations,
                                                     proxy: ProxyHandler(server: self, target: nil, connection: nextConnection()))
                }
            }
        let bound: Channel
        do { bound = try bootstrap.bind(host: allowLAN ? "0.0.0.0" : "127.0.0.1", port: port).wait() } catch {
            stop()
            throw error
        }
        channel = bound
        port = bound.localAddress?.port ?? port
        syncReverseProxies()
    }

    var eventLoop: EventLoop? { group?.next() }

    // MARK: Reverse proxies

    private let reverse = NIOLockedValueBox<[UUID: (rule: ReverseProxyRule, channel: Channel)]>([:])
    private let reverseErrorBox = NIOLockedValueBox<[UUID: String]>([:])
    /// Why a reverse proxy is not listening, by rule id (a port in use, for one).
    public var reverseErrors: [UUID: String] { reverseErrorBox.withLockedValue { $0 } }

    /// Binds a loopback listener per enabled reverse proxy rule and closes those no longer wanted.
    func syncReverseProxies() {
        guard let group else { return }
        let wanted = rules.withLockedValue { $0.reverseProxies.filter(\.enabled) }
        let stale = reverse.withLockedValue { open -> [Channel] in
            let keep = Set(wanted.map(\.id))
            var out: [Channel] = []
            for (id, entry) in open where !keep.contains(id) || wanted.first(where: { $0.id == id }) != entry.rule {
                out.append(entry.channel); open[id] = nil
            }
            return out
        }
        for channel in stale { try? channel.close().wait() }
        reverseErrorBox.withLockedValue { errors in errors = errors.filter { id, _ in wanted.contains { $0.id == id } } }
        for rule in wanted where reverse.withLockedValue({ $0[rule.id] == nil }) {
            let target = ProxyHandler.Target(host: rule.remoteHost, port: rule.remotePort, tls: rule.tls, reverse: true)
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [self] channel in
                    channel.eventLoop.makeCompletedFuture {
                        try ProxyHandler.addHTTPHandlers(channel.pipeline.syncOperations,
                                                         proxy: ProxyHandler(server: self, target: target, connection: nextConnection()))
                    }
                }
            do {
                let channel = try bootstrap.bind(host: "127.0.0.1", port: rule.localPort).wait()
                reverse.withLockedValue { $0[rule.id] = (rule, channel) }
                reverseErrorBox.withLockedValue { $0[rule.id] = nil }
            } catch {
                reverseErrorBox.withLockedValue { $0[rule.id] = "Cannot listen on 127.0.0.1:\(rule.localPort): \(error)" }
            }
        }
    }

    /// Closes the listener and every open connection.
    public func stop() {
        for entry in reverse.withLockedValue({ r -> [Channel] in defer { r.removeAll() }; return r.values.map(\.channel) }) {
            try? entry.close().wait()
        }
        try? channel?.close().wait()
        channel = nil
        group?.shutdownGracefully { _ in }
        group = nil
    }
}

/// Handles one client connection: plain HTTP, CONNECT (tunnel or intercept), and intercepted HTTPS requests.
final class ProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Where requests on this connection go: the decrypted inside of a CONNECT (TLS), or a reverse proxy's server.
    struct Target { var host: String; var port: Int; var tls = true; var reverse = false }

    let server: ProxyServer
    /// Set when this connection is the decrypted inside of a CONNECT: requests go to this host over TLS.
    let target: Target?
    /// Identifies the client connection (shared by the decrypted inside of a CONNECT), for app lookup.
    let connection: Int
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var flow: Flow?
    private var upstream: Channel?
    private var sawRequest = false
    /// The client is another device on the network (LAN mode), not this Mac.
    var fromNetwork = false
    /// A request is being answered.
    private var busy = false
    private var responsePlan = ResponsePlan()
    /// The client half-closed its side.
    private var clientDone = false

    init(server: ProxyServer, target: Target?, connection: Int) {
        self.server = server
        self.target = target
        self.connection = connection
    }

    /// NIO's server pipeline pairs the decoder with the encoder, so responses to HEAD carry no body or chunk terminator,
    /// and validates outgoing headers (edited at a breakpoint, they are user input).
    static func addHTTPHandlers(_ ops: ChannelPipeline.SynchronousOperations, proxy: ProxyHandler) throws {
        try ops.configureHTTPServerPipeline(withPipeliningAssistance: true, withErrorHandling: true)
        try ops.addHandler(proxy)
    }

    /// ponytail: request bodies are buffered whole before forwarding, up to this; stream them if huge uploads matter.
    static let requestBodyLimit = 256 << 20
    /// Devices on the network get less: they are not this Mac's own apps.
    static let networkBodyLimit = 32 << 20

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            sawRequest = true
            busy = true
            head = h
            body.clear()
            if h.headers["Expect"].contains(where: { $0.lowercased() == "100-continue" }) {
                context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: h.version, status: .continue))), promise: nil)
            }
        case .body(var chunk):
            guard head != nil else { return }
            guard body.readableBytes + chunk.readableBytes <= (fromNetwork ? Self.networkBodyLimit : Self.requestBodyLimit) else {
                head = nil
                body.clear()
                return respond(context: context, version: .http1_1, status: .payloadTooLarge,
                               text: "Sekisho buffers request bodies up to \(Self.requestBodyLimit >> 20) MB\n", close: true)
            }
            body.writeBuffer(&chunk)
        case .end:
            guard let h = head else { return }
            head = nil
            // CONNECT is handled at .end so the decoder has nothing left to emit when the pipeline is swapped.
            if h.method == .CONNECT {
                guard target == nil else {
                    return respond(context: context, version: h.version, status: .methodNotAllowed, text: "CONNECT inside a decrypted connection\n", close: true)
                }
                return connect(context: context, head: h)
            }
            forward(context: context, head: h)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // A failed handshake before the first request means the client refused Sekisho's certificate.
        // (A client that connects and leaves without TLS, like a browser preconnect, is not that.)
        if let target, !sawRequest, case NIOSSLError.handshakeFailed = error {
            var f = newFlow(context)
            f.scheme = "https"; f.method = "CONNECT"; f.host = target.host; f.port = target.port
            f.error = "The client refused Sekisho's certificate (\(error)). Trust the Sekisho CA, or the app pins its certificates."
            f.ended = Date()
            server.emit(f)
        } else if var f = flow, f.ended == nil {
            f.error = "\(error)"
            f.ended = Date()
            server.emit(f)
        }
        context.close(promise: nil)
    }

    /// The client finished sending. Close once the response it is waiting for is out (now, if there is none),
    /// instead of leaving it waiting on a connection that will never carry another request.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard case ChannelEvent.inputClosed = event else { return context.fireUserInboundEventTriggered(event) }
        clientDone = true
        if !busy { context.close(promise: nil) }
    }

    /// Called after a response's end is written.
    func responseFinished(_ context: ChannelHandlerContext, after written: EventLoopFuture<Void>) {
        busy = false
        if clientDone { written.whenComplete { _ in context.close(promise: nil) } }
    }

    func channelActive(context: ChannelHandlerContext) {
        guard Self.isLocalNetwork(context.channel.remoteAddress) else {
            // Not this Mac and not the local network: no proxy for the internet.
            context.close(promise: nil)
            return
        }
        fromNetwork = !Self.isLoopback(context.channel.remoteAddress)
        if target == nil, let port = context.channel.remoteAddress?.port, Self.isLoopback(context.channel.remoteAddress) {
            server.lookup.resolve(port: port, connection: connection)
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        context.fireChannelInactive()
    }

    // MARK: CONNECT

    private func connect(context: ChannelHandlerContext, head h: HTTPRequestHead) {
        guard let (host, port) = Self.splitAuthority(h.uri, defaultPort: 443) else {
            return respond(context: context, version: h.version, status: .badRequest, text: "CONNECT needs host:port\n")
        }
        let rules = server.rules.withLockedValue { $0 }
        // A row only for tunnels and blocks: a decrypted CONNECT shows up as the requests inside it.
        func connectFlow() -> Flow {
            var f = newFlow(context)
            f.method = "CONNECT"; f.scheme = "https"; f.host = host; f.port = port; f.path = ""
            f.requestHeaders = h.headers.map { Flow.Header($0.name, $0.value) }
            return f
        }
        if rules.blocks(host) {
            var f = connectFlow()
            f.blocked = true; f.status = 403; f.reason = "Blocked by Sekisho"; f.ended = Date()
            server.emit(f)
            return respond(context: context, version: h.version, status: .forbidden, text: "Blocked by Sekisho\n", close: true)
        }
        if isLoop(host: host, port: port) {
            return respond(context: context, version: h.version, status: .loopDetected, text: "That is Sekisho itself\n", close: true)
        }
        if rules.intercepts(host) {
            let sslContext: NIOSSLContext
            do { sslContext = try server.ca.serverContext(for: host) } catch {
                return respond(context: context, version: h.version, status: .internalServerError, text: "Certificate: \(error)\n", close: true)
            }
            let pipeline = context.pipeline, channel = context.channel
            Self.stripHTTP(pipeline)
            // Written raw: the HTTP encoder would frame a body onto it.
            channel.writeAndFlush(ByteBuffer(string: Self.established), promise: nil)
            do {
                let ops = pipeline.syncOperations
                try ops.addHandler(NIOSSLServerHandler(context: sslContext), position: .first)
                let inner = ProxyHandler(server: server, target: Target(host: host, port: port), connection: connection)
                inner.fromNetwork = fromNetwork
                try Self.addHTTPHandlers(ops, proxy: inner)
            } catch {
                channel.close(promise: nil)
            }
            return
        }
        // Not on the SSL Proxying list: pass the bytes through untouched.
        var f = connectFlow()
        f.kind = .tunnel
        server.emit(f)
        let flowBox = FlowBox(f, server: server)
        server.trackTunnel(host: host, client: context.channel)
        server.openUpstream(on: context.eventLoop, host: host, port: port, tunnel: true, halfClosure: true, fromNetwork: fromNetwork)
            .whenComplete { [self] result in
                switch result {
                case .failure(let error):
                    flowBox.finish(error: "Could not reach \(host):\(port): \(error)")
                    respond(context: context, version: h.version, status: .badGateway, text: "Could not reach \(host):\(port)\n", close: true)
                case .success(let (peer, _, _)):
                    // The app gave up (or the host was just decrypted) while this was connecting.
                    guard context.channel.isActive else { peer.close(promise: nil); return }
                    upstream = peer
                    Self.glue(client: context.channel, upstream: peer, flow: flowBox, reply: Self.established)
                }
            }
    }

    /// Removes the HTTP server handlers (outer or decrypted pipeline alike) so raw bytes can flow.
    /// Called on the event loop, in one go, so no read lands in between.
    private static func stripHTTP(_ pipeline: ChannelPipeline) {
        let ops = pipeline.syncOperations
        func drop<H: RemovableChannelHandler>(_ type: H.Type) {
            if let handler = try? ops.handler(type: type) { ops.removeHandler(handler, promise: nil) }
        }
        drop(ProxyHandler.self)
        drop(HTTPServerProtocolErrorHandler.self)
        drop(NIOHTTPResponseHeadersValidator.self)
        drop(HTTPServerPipelineHandler.self)
        drop(HTTPResponseEncoder.self)
        drop(ByteToMessageHandler<HTTPRequestDecoder>.self)
    }

    static let established = "HTTP/1.1 200 Connection Established\r\n\r\n"

    private static func glue(client channel: Channel, upstream: Channel, flow: FlowBox, reply: String? = nil) {
        let client = channel.pipeline
        let (a, b) = GlueHandler.pair(flow: flow)
        stripHTTP(client)
        if let reply { channel.writeAndFlush(ByteBuffer(string: reply), promise: nil) }
        do {
            try client.syncOperations.addHandler(a)
            try upstream.pipeline.syncOperations.addHandler(b)
        } catch {
            client.close(promise: nil)
            upstream.close(promise: nil)
        }
    }

    // MARK: Requests

    private func newFlow(_ context: ChannelHandlerContext) -> Flow {
        var f = Flow(id: server.nextID())
        f.clientPort = context.channel.remoteAddress?.port
        f.connection = connection
        return f
    }

    private func forward(context: ChannelHandlerContext, head h: HTTPRequestHead) {
        var host: String, port: Int, scheme: String, path: String
        if let target {
            (host, port, scheme, path) = (target.host, target.port, target.tls ? "https" : "http", h.uri)
        } else if let url = URLComponents(string: h.uri), url.scheme?.lowercased() == "http", let urlHost = url.host, !urlHost.isEmpty {
            host = urlHost
            port = url.port ?? 80
            scheme = "http"
            path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
            if let q = url.percentEncodedQuery { path += "?" + q }
        } else {
            return serveSelf(context: context, head: h)
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard Flow.isValidHost(host) else {
            return respond(context: context, version: h.version, status: .badRequest, text: "Not a valid host\n", close: true)
        }
        if host.lowercased() == "sekisho.ca" { return serveSelf(context: context, head: h) }

        var f = newFlow(context)
        f.scheme = scheme; f.method = h.method.rawValue; f.host = host; f.port = port; f.path = path
        f.httpVersion = "HTTP/\(h.version.major).\(h.version.minor)"
        f.requestHeaders = h.headers.map { Flow.Header($0.name, $0.value) }
        if target?.reverse == true {
            // The app asked localhost; the server expects its own name.
            f.requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Host") == .orderedSame }
            f.requestHeaders.insert(Flow.Header("Host", f.authority), at: 0)
        }
        f.requestBody = Data(body.readableBytesView)
        let keepAlive = h.isKeepAlive
        let rules = server.rules.withLockedValue { $0 }

        if let remote = rules.mapRemote(for: f), !remote.apply(to: &f) {
            f.error = "Map Remote: \"\(remote.destination)\" is not a URL"
        }
        if rules.blocks(f.host) {
            f.blocked = true; f.status = 403; f.reason = "Blocked by Sekisho"; f.ended = Date()
            server.emit(f)
            return respond(context: context, version: h.version, status: .forbidden, text: "Blocked by Sekisho\n", keepAlive: keepAlive)
        }
        if isLoop(host: f.host, port: f.port) {
            return respond(context: context, version: h.version, status: .loopDetected, text: "That is Sekisho itself\n", close: true)
        }
        let upgrade = h.headers.contains(name: "Upgrade") && h.headers[canonicalForm: "Connection"].contains { $0.lowercased() == "upgrade" }
        if upgrade {
            f.kind = .upgrade
            server.emit(f)
            return startUpgrade(context: context, head: upstreamHead(for: f, keepUpgrade: true), flow: FlowBox(f, server: server), tls: f.scheme == "https")
        }
        if !rules.records(f.host) {
            // Not on the Allow List: straight through, no tools.
            flow = f
            return dispatch(context: context, flow: f, keepAlive: keepAlive, clientVersion: h.version, plan: ResponsePlan())
        }
        if rules.noCaching { Self.noCache(request: &f) }
        if let local = rules.mapLocal(for: f) {
            if local.directory?.isEmpty == false {
                // A folder mapping: serve the file if it is there, otherwise the request goes to the server.
                if let file = local.directoryFile(for: f) {
                    var rule = local
                    rule.filePath = file.path
                    rule.directory = nil
                    rule.contentType = Self.mimeType(file.pathExtension)
                    return serveLocal(context: context, flow: f, rule: rule, keepAlive: keepAlive, version: h.version)
                }
            } else {
                return serveLocal(context: context, flow: f, rule: local, keepAlive: keepAlive, version: h.version)
            }
        }
        let script = rules.script(for: f)
        let breakpoint = rules.breakpoint(for: f)
        let throttle = rules.throttle(for: f)
        if rules.spoofedAddress(f.host) != nil { f.interventions.insert(.spoofed) }
        if throttle != nil { f.interventions.insert(.throttled) }
        let plan = ResponsePlan(script: script?.response == true ? script : nil, breakpoint: breakpoint?.response == true,
                                downKbps: throttle?.downKbps ?? 0)
        flow = f
        server.emit(f)
        func send(_ f: Flow) {
            guard context.channel.isActive else { return }
            // Network Conditions: the latency, plus the time the body takes at the upload cap.
            var delay = throttle?.latencyMs ?? 0
            if let up = throttle?.upKbps, up > 0 { delay += f.requestBody.count * 8 / up }
            if delay > 0 {
                context.eventLoop.scheduleTask(in: .milliseconds(Int64(delay))) { [self] in
                    dispatch(context: context, flow: f, keepAlive: keepAlive, clientVersion: h.version, plan: plan)
                }
            } else {
                dispatch(context: context, flow: f, keepAlive: keepAlive, clientVersion: h.version, plan: plan)
            }
        }
        runScript(context: context, stage: .request, rule: script, flow: f) { [self] scripted in
            var f = scripted
            if f != flow { flow = f; server.emit(f) }
            guard breakpoint?.request == true else { return send(f) }
            f.interventions.insert(.hold)
            flow = f
            server.emit(f)
            pause(context: context, stage: .request, flow: f) { [self] edited in
                guard var edited else {
                    return fail(context: context, status: .badGateway, message: "Aborted at the breakpoint", aborted: true)
                }
                if edited != f { edited.interventions.insert(.edited) }
                flow = edited
                server.emit(edited)
                send(edited)
            }
        }
    }

    /// What happens to the response: a script and/or a breakpoint need it whole; a bandwidth cap paces it.
    struct ResponsePlan {
        var script: ScriptRule?
        var breakpoint = false
        var downKbps = 0
        var holds: Bool { script != nil || breakpoint }
    }

    /// Runs a script stage off the event loop and continues on it.
    private func runScript(context: ChannelHandlerContext, stage: BreakpointStage, rule: ScriptRule?, flow: Flow, then: @escaping (Flow) -> Void) {
        guard let rule else { return then(flow) }
        let promise = context.eventLoop.makePromise(of: Flow.self)
        server.scripts.run(stage, rule: rule, flow: flow) { promise.succeed($0) }
        promise.futureResult.whenSuccess(then)
    }

    static func noCache(request f: inout Flow) {
        f.requestHeaders.removeAll { ["if-none-match", "if-modified-since", "cache-control", "pragma"].contains($0.name.lowercased()) }
        f.requestHeaders += [Flow.Header("Cache-Control", "no-cache"), Flow.Header("Pragma", "no-cache")]
    }

    static func noCache(response headers: inout HTTPHeaders) {
        for name in ["ETag", "Last-Modified", "Expires", "Cache-Control", "Pragma", "Age"] { headers.remove(name: name) }
        headers.add(name: "Cache-Control", value: "no-store, no-cache, must-revalidate")
        headers.add(name: "Pragma", value: "no-cache")
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "json": "application/json"
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "xml": "application/xml"
        case "txt": "text/plain; charset=utf-8"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }

    /// Hands `flow` to the breakpoint handler and continues on this connection's event loop.
    private func pause(context: ChannelHandlerContext, stage: BreakpointStage, flow: Flow, then: @escaping (Flow?) -> Void) {
        guard let handler = server.breakpointHandler else { return then(flow) }
        let promise = context.eventLoop.makePromise(of: Flow?.self)
        Task { promise.succeed(await handler(stage, flow)) }
        promise.futureResult.whenSuccess(then)
    }

    /// The request Sekisho sends upstream, built from the (possibly edited) flow.
    private func upstreamHead(for f: Flow, keepUpgrade: Bool = false) -> HTTPRequestHead {
        var headers = HTTPHeaders(f.requestHeaders.map { ($0.name, $0.value) })
        Self.stripHopByHop(&headers, keepUpgrade: keepUpgrade)
        headers.remove(name: "Expect")
        // No permessage-deflate: compressed frames could not be shown. Both ends work without it.
        if keepUpgrade { headers.remove(name: "Sec-WebSocket-Extensions") }
        if !headers.contains(name: "Host") { headers.add(name: "Host", value: f.authority) }
        if !keepUpgrade && (!f.requestBody.isEmpty || headers.contains(name: "Content-Length") || headers.contains(name: "Transfer-Encoding")) {
            headers.remove(name: "Transfer-Encoding")
            headers.replaceOrAdd(name: "Content-Length", value: String(f.requestBody.count))
        }
        return HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: f.method), uri: Flow.wireTarget(f.path), headers: headers)
    }

    private func dispatch(context: ChannelHandlerContext, flow f: Flow, keepAlive: Bool, clientVersion: HTTPVersion, plan: ResponsePlan) {
        responsePlan = plan
        let head = upstreamHead(for: f)
        let requestBody = ByteBuffer(bytes: f.requestBody)
        let host = f.host
        let tls = f.scheme == "https"
        if let problem = f.wireProblem { return fail(context: context, status: .badRequest, message: problem) }
        stamp { $0.connectStart = Date() }
        server.openUpstream(on: context.eventLoop, host: host, port: f.port, tunnel: tls, fromNetwork: fromNetwork)
            .flatMapThrowing { [server, self] conn -> (Channel, Bool, String?) in
                let ops = conn.channel.pipeline.syncOperations
                if tls {
                    let sni = CertificateAuthority.ipBytes(host) == nil ? host : nil
                    try ops.addHandler(NIOSSLClientHandler(context: server.upstreamTLS, serverHostname: sni))
                }
                try ops.addHTTPClientHandlers()
                try ops.addHandler(UpstreamHandler(client: context, owner: self, keepAlive: keepAlive,
                                                   clientVersion: clientVersion, hold: plan.holds, downKbps: plan.downKbps))
                return (conn.channel, conn.absolute, conn.auth)
            }
            .whenComplete { [self] result in
                switch result {
                case .failure(let error):
                    fail(context: context, status: .badGateway, message: "Could not reach \(f.authority): \(error)")
                case .success(let (channel, absolute, auth)):
                    guard context.channel.isActive else { channel.close(promise: nil); return }
                    upstream = channel
                    stamp { $0.connected = Date() }
                    var head = head
                    // Plain HTTP through an upstream proxy goes in absolute form.
                    if absolute {
                        head.uri = "http://\(f.authority)\(head.uri)"
                        if let auth { head.headers.replaceOrAdd(name: "Proxy-Authorization", value: auth) }
                    }
                    channel.write(HTTPClientRequestPart.head(head), promise: nil)
                    if requestBody.readableBytes > 0 { channel.write(HTTPClientRequestPart.body(.byteBuffer(requestBody)), promise: nil) }
                    channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenSuccess { [self] in stamp { $0.sent = Date() } }
                }
            }
    }

    /// ponytail: Map Local files are read whole, up to this size; stream them if someone maps a disk image.
    static let mapLocalFileLimit = 64 << 20

    private func serveLocal(context: ChannelHandlerContext, flow: Flow, rule: MapLocalRule, keepAlive: Bool, version: HTTPVersion) {
        guard let path = rule.filePath, !path.isEmpty else {
            return finishLocal(context: context, flow: flow, rule: rule, body: .success(Data(rule.body.utf8)), keepAlive: keepAlive, version: version)
        }
        // Read off the event loop: a slow disk (or a FIFO) must not stall every connection on it.
        let promise = context.eventLoop.makePromise(of: Data.self)
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw MapLocalError("not a regular file") }
                guard (values.fileSize ?? 0) <= Self.mapLocalFileLimit else { throw MapLocalError("larger than \(Self.mapLocalFileLimit >> 20) MB") }
                promise.succeed(try Data(contentsOf: url))
            } catch {
                promise.fail(error)
            }
        }
        promise.futureResult.whenComplete { [self] result in
            finishLocal(context: context, flow: flow, rule: rule, body: result, keepAlive: keepAlive, version: version)
        }
    }

    struct MapLocalError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func finishLocal(context: ChannelHandlerContext, flow: Flow, rule: MapLocalRule, body: Result<Data, Error>,
                             keepAlive: Bool, version: HTTPVersion) {
        var f = flow
        f.interventions.insert(.mapLocal)
        switch body {
        case .success(let data):
            f.responseBody = data
            f.status = rule.status
            f.reason = HTTPResponseStatus(statusCode: rule.status).reasonPhrase
        case .failure(let error):
            f.error = "Map Local: cannot read \(rule.filePath ?? ""): \(error.localizedDescription)"
            f.responseBody = Data((f.error! + "\n").utf8)
            f.status = 500
            f.reason = "Map Local Failed"
        }
        f.responseHeaders = [Flow.Header("Content-Type", body.isSuccess ? rule.contentType : "text/plain; charset=utf-8"),
                             Flow.Header("Content-Length", String(f.responseBody.count)), Flow.Header("X-Sekisho", "Map Local")]
        f.responseSize = f.responseBody.count
        f.ended = Date()
        server.emit(f)
        writeResponse(context: context, flow: f, keepAlive: keepAlive, clientVersion: version)
    }

    /// Writes a whole response from a flow: Map Local, and responses held at a breakpoint.
    private func writeResponse(context: ChannelHandlerContext, flow f: Flow, keepAlive: Bool, clientVersion: HTTPVersion) {
        var headers = HTTPHeaders(f.responseHeaders.map { ($0.name, $0.value) })
        Self.stripHopByHop(&headers, keepUpgrade: false)
        headers.remove(name: "Transfer-Encoding")
        let status = HTTPResponseStatus(statusCode: f.status ?? 200, reasonPhrase: f.reason)
        let bodyless = f.method == "HEAD" || (100..<200).contains(status.code) || status.code == 204 || status.code == 304
        if !bodyless { headers.replaceOrAdd(name: "Content-Length", value: String(f.responseBody.count)) }
        if !keepAlive { headers.replaceOrAdd(name: "Connection", value: "close") }
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: clientVersion, status: status, headers: headers))), promise: nil)
        if !bodyless, !f.responseBody.isEmpty {
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: f.responseBody)))), promise: nil)
        }
        let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if !keepAlive { done.whenComplete { _ in context.close(promise: nil) } }
        responseFinished(context, after: done)
    }

    private func startUpgrade(context: ChannelHandlerContext, head: HTTPRequestHead, flow: FlowBox, tls: Bool) {
        let host = flow.flow.host
        if let problem = flow.flow.wireProblem {
            flow.finish(error: problem)
            return respond(context: context, version: head.version, status: .badRequest, text: problem + "\n", close: true)
        }
        server.openUpstream(on: context.eventLoop, host: host, port: flow.flow.port, tunnel: true, halfClosure: true, fromNetwork: fromNetwork)
            .flatMapThrowing { [server] conn -> Channel in
                if tls {
                    let sni = CertificateAuthority.ipBytes(host) == nil ? host : nil
                    try conn.channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: server.upstreamTLS, serverHostname: sni))
                }
                return conn.channel
            }
            .whenComplete { [self] result in
                switch result {
                case .failure(let error):
                    flow.finish(error: "Could not reach \(host): \(error)")
                    respond(context: context, version: head.version, status: .badGateway, text: "Could not reach \(host)\n", close: true)
                case .success(let peer):
                    upstream = peer
                    var raw = "\(head.method.rawValue) \(head.uri) HTTP/1.1\r\n"
                    for (name, value) in head.headers { raw += "\(name): \(value)\r\n" }
                    raw += "\r\n"
                    peer.writeAndFlush(ByteBuffer(string: raw), promise: nil)
                    Self.glue(client: context.channel, upstream: peer, flow: flow)
                }
            }
    }

    // MARK: Upstream callbacks (on the client's event loop)

    /// Records a moment of the exchange in progress (on this connection's event loop).
    func stamp(_ change: (inout Flow.Timing) -> Void) {
        guard flow != nil else { return }
        change(&flow!.timing)
    }

    func upstreamHead(_ response: HTTPResponseHead) {
        guard var f = flow else { return }
        f.timing.firstByte = Date()
        f.status = Int(response.status.code)
        f.reason = response.status.reasonPhrase
        f.httpVersion = "HTTP/\(response.version.major).\(response.version.minor)"
        f.responseHeaders = response.headers.map { Flow.Header($0.name, $0.value) }
        flow = f
        server.emit(f)
    }

    func upstreamBody(_ chunk: ByteBuffer, whole: Bool = false) {
        guard var f = flow else { return }
        f.responseSize += chunk.readableBytes
        let room = whole ? Int.max : Flow.captureLimit - f.responseBody.count
        if room > 0 { f.responseBody.append(contentsOf: chunk.readableBytesView.prefix(room)) }
        if chunk.readableBytes > room { f.responseTruncated = true }
        flow = f
    }

    func upstreamEnd(error: String? = nil) {
        guard var f = flow, f.ended == nil else { return }
        f.ended = Date()
        f.error = error
        flow = nil
        upstream = nil
        server.emit(f)
    }

    /// A response that a script or a breakpoint needed whole has arrived: script first, then the breakpoint, then send it.
    func upstreamHeld(context: ChannelHandlerContext, keepAlive: Bool, clientVersion: HTTPVersion) {
        guard let f = flow else { return }
        upstream = nil
        let plan = responsePlan
        runScript(context: context, stage: .response, rule: plan.script, flow: f) { [self] scripted in
            var f = scripted
            func finish(_ out: Flow) {
                var out = out
                out.ended = Date()
                flow = nil
                server.emit(out)
                writeResponse(context: context, flow: out, keepAlive: keepAlive, clientVersion: clientVersion)
            }
            guard plan.breakpoint else { return finish(f) }
            f.interventions.insert(.hold)
            flow = f
            server.emit(f)
            pause(context: context, stage: .response, flow: f) { [self] edited in
                guard var edited else {
                    return fail(context: context, status: .badGateway, message: "Aborted at the breakpoint", aborted: true)
                }
                if edited != f { edited.interventions.insert(.edited) }
                finish(edited)
            }
        }
    }

    // MARK: Local responses

    private func fail(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String, aborted: Bool = false) {
        if aborted { flow?.interventions.insert(.aborted) }
        upstreamEnd(error: message)
        respond(context: context, version: .http1_1, status: status, text: message + "\n", close: true)
    }

    private func respond(context: ChannelHandlerContext, version: HTTPVersion, status: HTTPResponseStatus, text: String,
                         contentType: String = "text/plain; charset=utf-8", keepAlive: Bool = false, close: Bool = false) {
        var headers = HTTPHeaders([("Content-Type", contentType), ("Content-Length", String(text.utf8.count))])
        if close || !keepAlive { headers.add(name: "Connection", value: "close") }
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: version, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: text)))), promise: nil)
        let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if close || !keepAlive { done.whenComplete { _ in context.close(promise: nil) } }
        responseFinished(context, after: done)
    }

    /// Requests addressed to the proxy itself (or http://sekisho.ca): a landing page and the CA certificate.
    private func serveSelf(context: ChannelHandlerContext, head h: HTTPRequestHead) {
        let path = URLComponents(string: h.uri)?.path ?? h.uri
        if path == "/ca.pem" || path == "/ca" {
            return respond(context: context, version: h.version, status: .ok, text: server.ca.rootPEM,
                           contentType: "application/x-x509-ca-cert", keepAlive: h.isKeepAlive)
        }
        let page = """
        <!doctype html><meta charset="utf-8"><title>Sekisho</title>
        <body style="font: 15px -apple-system, sans-serif; max-width: 34em; margin: 4em auto; line-height: 1.5">
        <h1>Sekisho is running</h1>
        <p>To inspect HTTPS from this device, install and trust Sekisho's certificate:
        <a href="/ca.pem">download the Sekisho CA</a>.</p></body>
        """
        respond(context: context, version: h.version, status: .ok, text: page, contentType: "text/html; charset=utf-8", keepAlive: h.isKeepAlive)
    }

    private func isLoop(host: String, port: Int) -> Bool {
        port == server.port && ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host.lowercased())
    }

    static func stripHopByHop(_ headers: inout HTTPHeaders, keepUpgrade: Bool) {
        let listed = headers[canonicalForm: "Connection"].map { $0.lowercased() }.filter { !(keepUpgrade && $0 == "upgrade") }
        for name in ["Proxy-Connection", "Proxy-Authorization", "Keep-Alive", "TE", "Trailer"] + listed.map({ String($0) }) {
            headers.remove(name: name)
        }
        if !keepUpgrade {
            headers.remove(name: "Connection")
            headers.remove(name: "Upgrade")
        }
    }

    static func isLoopback(_ address: SocketAddress?) -> Bool {
        guard let ip = address?.ipAddress else { return false }
        return ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("127.") || ip == "::ffff:127.0.0.1"
    }

    static func isLocalNetwork(_ address: SocketAddress?) -> Bool {
        guard var ip = address?.ipAddress?.lowercased() else { return false }
        if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst(7)) }
        if isLoopback(address) { return true }
        let o = ip.split(separator: ".").compactMap { Int($0) }
        if o.count == 4 {
            return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
        }
        return ip.hasPrefix("fc") || ip.hasPrefix("fd") || ip.hasPrefix("fe8") || ip.hasPrefix("fe9") || ip.hasPrefix("fea") || ip.hasPrefix("feb")
    }

    static func splitAuthority(_ authority: String, defaultPort: Int) -> (String, Int)? {
        var host = authority, port = defaultPort
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            if rest.hasPrefix(":") { guard let p = Int(rest.dropFirst()) else { return nil }; port = p }
        } else if let colon = authority.lastIndex(of: ":") {
            host = String(authority[..<colon])
            guard let p = Int(authority[authority.index(after: colon)...]) else { return nil }
            port = p
        }
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        return (host, port)
    }
}

/// Reads the real server's response and relays it to the client part by part, while ProxyHandler records it.
final class UpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let client: ChannelHandlerContext
    private let owner: ProxyHandler
    private let keepAlive: Bool
    private let clientVersion: HTTPVersion
    /// Response breakpoint: collect the whole response, then hand it to the owner instead of relaying it.
    private let hold: Bool
    /// Network Conditions download cap in kilobits per second; 0 relays as fast as it comes.
    private let downKbps: Int
    private var cursor = NIODeadline.now()
    private var started = false
    private var finished = false

    init(client: ChannelHandlerContext, owner: ProxyHandler, keepAlive: Bool, clientVersion: HTTPVersion, hold: Bool = false, downKbps: Int = 0) {
        self.client = client
        self.owner = owner
        self.keepAlive = keepAlive
        self.clientVersion = clientVersion
        self.hold = hold
        self.downKbps = downKbps
    }

    /// Runs `write` when `bytes` would have arrived at the cap; in order, since the cursor only moves forward.
    /// ponytail: the server is read at full speed and the slow part is buffered here; fine for testing an app.
    private func paced(_ bytes: Int, _ write: @escaping () -> Void) {
        guard downKbps > 0 else { return write() }
        let now = NIODeadline.now()
        if cursor < now { cursor = now }
        cursor = cursor + .microseconds(Int64(bytes) * 8_000 / Int64(downKbps))
        client.eventLoop.scheduleTask(deadline: cursor, write)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(var response):
            if owner.server.rules.withLockedValue({ $0.noCaching }) { ProxyHandler.noCache(response: &response.headers) }
            owner.upstreamHead(response)
            guard !hold else { return }
            started = true
            ProxyHandler.stripHopByHop(&response.headers, keepUpgrade: false)
            response.version = clientVersion
            if !keepAlive { response.headers.add(name: "Connection", value: "close") }
            // Flushed now: server-sent events and long polls send headers long before any body.
            client.writeAndFlush(NIOAny(HTTPServerResponsePart.head(response)), promise: nil)
        case .body(let chunk):
            owner.upstreamBody(chunk, whole: hold)
            if !hold { paced(chunk.readableBytes) { [client] in client.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(chunk))), promise: nil) } }
        case .end:
            finished = true
            context.close(promise: nil)
            if hold { return owner.upstreamHeld(context: client, keepAlive: keepAlive, clientVersion: clientVersion) }
            paced(0) { [self] in
                owner.upstreamEnd()
                let done = client.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)))
                if !keepAlive { done.whenComplete { [client] _ in client.close(promise: nil) } }
                owner.responseFinished(client, after: done)
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls { owner.stamp { $0.secured = Date() } }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !finished else { return }
        finished = true
        let message = error is NIOSSLError || error is BoringSSLError
            ? "Upstream TLS failed: \(error). The server's certificate is not trusted by this Mac."
            : "Upstream error: \(error)"
        owner.upstreamEnd(error: message)
        if started {
            client.close(promise: nil)
        } else {
            let text = message + "\n"
            let headers = HTTPHeaders([("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", String(text.utf8.count)), ("Connection", "close")])
            client.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(version: clientVersion, status: .badGateway, headers: headers))), promise: nil)
            client.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: text)))), promise: nil)
            client.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { [client] _ in client.close(promise: nil) }
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished {
            finished = true
            owner.upstreamEnd(error: "The server closed the connection before the response finished.")
            client.close(promise: nil)
        }
        context.fireChannelInactive()
    }
}

/// Shared record for a tunnel or upgraded connection, updated from both sides of the glue (same event loop).
final class FlowBox: @unchecked Sendable {
    var flow: Flow
    let server: ProxyServer
    private var up = WebSocketFrames(afterHTTPHeader: false)
    private var down = WebSocketFrames(afterHTTPHeader: true)
    init(_ flow: Flow, server: ProxyServer) { self.flow = flow; self.server = server }

    /// WebSocket messages from one direction of an upgraded connection, recorded up to `Flow.messageLimit`.
    func frames(_ data: ByteBuffer, upstream: Bool) {
        guard flow.kind == .upgrade, flow.status == nil || flow.status == 101,
              flow.requestHeader("Upgrade")?.lowercased() == "websocket" else { return }
        let bytes = Data(data.readableBytesView)
        let decoded = upstream ? down.feed(bytes) : up.feed(bytes)
        guard !decoded.isEmpty else { return }
        for (kind, payload, length) in decoded where flow.messages.count < Flow.messageLimit {
            flow.messages.append(Flow.Message(id: flow.messages.count + 1, direction: upstream ? .received : .sent, kind: kind,
                                              time: Date(), payload: payload.prefix(256 << 10), length: length))
        }
        server.emit(flow)
    }

    func finish(error: String? = nil) {
        guard flow.ended == nil else { return }
        flow.ended = Date()
        if flow.error == nil { flow.error = error }
        server.emit(flow)
    }
}

/// Copies bytes between two channels, with backpressure, counting them into the flow.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    private let flow: FlowBox
    private let upstreamSide: Bool

    private init(flow: FlowBox, upstreamSide: Bool) {
        self.flow = flow
        self.upstreamSide = upstreamSide
    }

    static func pair(flow: FlowBox) -> (client: GlueHandler, upstream: GlueHandler) {
        let a = GlueHandler(flow: flow, upstreamSide: false), b = GlueHandler(flow: flow, upstreamSide: true)
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; partner = nil }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if upstreamSide {
            flow.flow.bytesDown += buffer.readableBytes
            // For upgraded connections, read the status line of the server's answer.
            if flow.flow.kind == .upgrade, flow.flow.status == nil,
               let line = buffer.getString(at: buffer.readerIndex, length: min(buffer.readableBytes, 200))?.split(separator: "\r\n").first {
                let parts = line.split(separator: " ", maxSplits: 2)
                if parts.count >= 2, let code = Int(parts[1]) {
                    flow.flow.status = code
                    flow.flow.reason = parts.count > 2 ? String(parts[2]) : ""
                    flow.server.emit(flow.flow)
                }
            }
        } else {
            flow.flow.bytesUp += buffer.readableBytes
        }
        flow.frames(buffer, upstream: upstreamSide)
        partner?.write(buffer)
    }

    func channelReadComplete(context: ChannelHandlerContext) { partner?.flush() }

    /// One side finished sending: pass the half-close on once everything before it is written.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event { partner?.closeOutputAfterWrites() } else { context.fireUserInboundEventTriggered(event) }
    }

    /// One side is gone: close the other only after the bytes already queued for it are out.
    func channelInactive(context: ChannelHandlerContext) {
        flow.finish()
        partner?.closeAfterWrites()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !GlueHandler.isOrdinaryHangUp(error, flow: flow.flow) { flow.flow.error = flow.flow.error ?? "\(error)" }
        context.close(promise: nil)
    }

    /// Peers often reset instead of closing politely: after a WebSocket close frame, a TLS peer that skips
    /// close_notify, or a reset once the answer is in. That is how the connection ended, not a failure.
    static func isOrdinaryHangUp(_ error: Error, flow: Flow) -> Bool {
        if flow.messages.contains(where: { $0.kind == .close }) { return true }
        if let tls = error as? NIOSSLError, case .uncleanShutdown = tls { return true }
        if let io = error as? IOError, [ECONNRESET, EPIPE].contains(io.errnoCode) { return flow.bytesDown > 0 }
        return false
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.resumeRead() }
    }

    func read(context: ChannelHandlerContext) {
        if partner?.isWritable ?? true { context.read() } else { pendingRead = true }
    }

    private var isWritable: Bool { context?.channel.isWritable ?? false }
    private func write(_ data: ByteBuffer) { context?.write(wrapOutboundOut(data), promise: nil) }
    private func flush() { context?.flush() }
    private func closeAfterWrites() {
        guard let context else { return }
        context.writeAndFlush(wrapOutboundOut(ByteBuffer())).whenComplete { _ in context.close(promise: nil) }
    }
    private func closeOutputAfterWrites() {
        guard let context else { return }
        context.writeAndFlush(wrapOutboundOut(ByteBuffer())).whenComplete { _ in
            // TLS (a WebSocket inside SSL Proxying) cannot half-close; close it whole.
            let done = context.eventLoop.makePromise(of: Void.self)
            done.futureResult.whenFailure { _ in context.close(promise: nil) }
            context.close(mode: .output, promise: done)
        }
    }
    private func resumeRead() {
        if pendingRead { pendingRead = false; context?.read() }
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
