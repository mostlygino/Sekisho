import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Another proxy Sekisho sends its own outgoing traffic through (a company proxy, Charles, Burp).
public struct UpstreamProxy: Codable, Sendable, Equatable {
    public var enabled = true
    public var host: String
    public var port: Int
    public var username = ""
    /// Kept in the Keychain by the app, never written with the rules.
    public var password = ""
    /// Hosts reached directly, not through the upstream proxy.
    public var bypass: [String] = ["localhost", "127.0.0.1", "*.local"]

    public init(host: String, port: Int) { self.host = host; self.port = port }

    enum CodingKeys: String, CodingKey { case enabled, host, port, username, bypass }

    public func bypasses(_ host: String) -> Bool { bypass.contains { ProxyRules.matches(host, $0) } }

    var authorization: String? {
        username.isEmpty ? nil : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

extension ProxyServer {
    /// Opens a connection to `host:port`: directly (after DNS Spoofing), or through the upstream proxy.
    /// Through a proxy, TLS and raw tunnels (`tunnel`) are set up with CONNECT; plain HTTP is sent to the proxy in
    /// absolute form, which `absolute` reports so the caller writes `http://host/path` as the request target.
    /// `fromNetwork`: the client is another device, which must not reach this Mac's own services through Sekisho.
    func openUpstream(on loop: EventLoop, host: String, port: Int, tunnel: Bool, halfClosure: Bool = false, fromNetwork: Bool = false)
        -> EventLoopFuture<(channel: Channel, absolute: Bool, auth: String?)> {
        guard Flow.isValidHost(host) else {
            return loop.makeFailedFuture(UpstreamProxyError(description: "\"\(host)\" is not a valid hostname"))
        }
        if fromNetwork, LocalDestination.isThisMac(host) {
            return loop.makeFailedFuture(UpstreamProxyError(description: "Devices on the network cannot reach this Mac's own services through Sekisho"))
        }
        let r = rules.withLockedValue { $0 }
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(ProxyServer.connectTimeout)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .channelOption(.allowRemoteHalfClosure, value: halfClosure)
        guard let proxy = r.upstreamProxy, proxy.enabled, !proxy.host.isEmpty, !proxy.bypasses(host) else {
            return bootstrap.connect(host: r.spoofedAddress(host) ?? host, port: port).flatMapThrowing { channel in
                // A name can resolve to this Mac (DNS rebinding): check where the socket actually went.
                if fromNetwork, LocalDestination.isThisMac(channel.remoteAddress?.ipAddress ?? "") {
                    channel.close(promise: nil)
                    throw UpstreamProxyError(description: "Devices on the network cannot reach this Mac's own services through Sekisho")
                }
                return (channel, false, nil)
            }
        }
        return bootstrap.connect(host: proxy.host, port: proxy.port).flatMap { channel in
            guard tunnel else { return loop.makeSucceededFuture((channel, true, proxy.authorization)) }
            let done = loop.makePromise(of: Void.self)
            do {
                try channel.pipeline.syncOperations.addHandler(ProxyConnectHandler(done: done))
            } catch {
                return loop.makeFailedFuture(error)
            }
            let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
            var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
            if let auth = proxy.authorization { request += "Proxy-Authorization: \(auth)\r\n" }
            request += "\r\n"
            channel.writeAndFlush(ByteBuffer(string: request), promise: nil)
            return done.futureResult.map { (channel, false, nil) }.flatMapErrorThrowing { error in
                channel.close(promise: nil)
                throw error
            }
        }
    }
}

struct UpstreamProxyError: Error, CustomStringConvertible {
    let description: String
}

/// Reads the upstream proxy's answer to CONNECT, then steps aside.
final class ProxyConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    private var buffer = ByteBuffer()
    private let done: EventLoopPromise<Void>

    init(done: EventLoopPromise<Void>) { self.done = done }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = unwrapInboundIn(data)
        buffer.writeBuffer(&chunk)
        guard let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes), let end = text.range(of: "\r\n\r\n") else {
            if buffer.readableBytes > 16 << 10 { done.fail(UpstreamProxyError(description: "The upstream proxy's answer is too long")) }
            return
        }
        let status = text[..<end.lowerBound].split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = status.split(separator: " ")
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        if parts.count >= 2, parts[1] == "200" {
            done.succeed(())
        } else {
            done.fail(UpstreamProxyError(description: "The upstream proxy refused: \(status)"))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { done.fail(error) }
    func channelInactive(context: ChannelHandlerContext) {
        done.fail(UpstreamProxyError(description: "The upstream proxy closed the connection"))
        context.fireChannelInactive()
    }
}

/// This Mac's own addresses, which network clients must not be forwarded to.
enum LocalDestination {
    static func isThisMac(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") || h == "0.0.0.0" || h == "::" || h == "::1" || h.hasPrefix("127.") { return true }
        if h.hasPrefix("::ffff:") { return isThisMac(String(h.dropFirst(7))) }
        return ownAddresses().contains(h)
    }

    static func ownAddresses() -> Set<String> {
        var out = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = p.pointee.ifa_addr, [UInt8(AF_INET), UInt8(AF_INET6)].contains(addr.pointee.sa_family) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.insert(String(cString: host).split(separator: "%").first.map { String($0).lowercased() } ?? "")
            }
        }
        return out
    }
}
