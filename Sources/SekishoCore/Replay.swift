import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

extension ProxyServer {
    /// Sends `request` (Repeat, or a request built in Compose) straight to its server and records it as a new flow.
    /// Returns the new flow's id. Tool rules do not apply: what you send is what goes out.
    @discardableResult
    public func replay(_ request: Flow) -> Int {
        var f = Flow(id: nextID())
        f.scheme = request.scheme; f.method = request.method; f.host = request.host; f.port = request.port
        f.path = request.path; f.requestHeaders = request.requestHeaders; f.requestBody = request.requestBody
        f.interventions = [.replay]
        onFlow(f)
        let box = ReplayBox(flow: f, server: self)
        if let problem = f.wireProblem {
            box.finish(error: problem)
            return f.id
        }
        guard let loop = eventLoop else {
            box.finish(error: "Sekisho is not running")
            return f.id
        }
        var headers = HTTPHeaders(f.requestHeaders.map { ($0.name, $0.value) })
        ProxyHandler.stripHopByHop(&headers, keepUpgrade: false)
        if !headers.contains(name: "Host") { headers.add(name: "Host", value: f.authority) }
        headers.remove(name: "Transfer-Encoding")
        if !f.requestBody.isEmpty || headers.contains(name: "Content-Length") {
            headers.replaceOrAdd(name: "Content-Length", value: String(f.requestBody.count))
        }
        headers.replaceOrAdd(name: "Connection", value: "close")
        let head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: f.method), uri: Flow.wireTarget(f.path), headers: headers)
        let body = ByteBuffer(bytes: f.requestBody)
        let host = f.host, tls = f.scheme == "https"
        openUpstream(on: loop, host: host, port: f.port, tunnel: tls)
            .flatMapThrowing { [upstreamTLS] conn -> (Channel, Bool, String?) in
                let ops = conn.channel.pipeline.syncOperations
                if tls {
                    let sni = CertificateAuthority.ipBytes(host) == nil ? host : nil
                    try ops.addHandler(NIOSSLClientHandler(context: upstreamTLS, serverHostname: sni))
                }
                try ops.addHTTPClientHandlers()
                try ops.addHandler(ReplayHandler(box: box))
                return (conn.channel, conn.absolute, conn.auth)
            }
            .whenComplete { result in
                switch result {
                case .failure(let error): box.finish(error: "Could not reach \(f.authority): \(error)")
                case .success(let (channel, absolute, auth)):
                    var head = head
                    if absolute {
                        head.uri = "http://\(f.authority)\(head.uri)"
                        if let auth { head.headers.replaceOrAdd(name: "Proxy-Authorization", value: auth) }
                    }
                    channel.write(HTTPClientRequestPart.head(head), promise: nil)
                    if body.readableBytes > 0 { channel.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil) }
                    channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                }
            }
        return f.id
    }
}

final class ReplayBox: @unchecked Sendable {
    var flow: Flow
    let server: ProxyServer
    init(flow: Flow, server: ProxyServer) { self.flow = flow; self.server = server }
    func finish(error: String? = nil) {
        guard flow.ended == nil else { return }
        flow.ended = Date()
        flow.error = error
        server.onFlow(flow)
    }
}

final class ReplayHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    let box: ReplayBox
    init(box: ReplayBox) { self.box = box }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            box.flow.status = Int(h.status.code)
            box.flow.reason = h.status.reasonPhrase
            box.flow.responseHeaders = h.headers.map { Flow.Header($0.name, $0.value) }
            box.server.onFlow(box.flow)
        case .body(let chunk):
            box.flow.responseSize += chunk.readableBytes
            let room = Flow.captureLimit - box.flow.responseBody.count
            if room > 0 { box.flow.responseBody.append(contentsOf: chunk.readableBytesView.prefix(room)) }
            if chunk.readableBytes > room { box.flow.responseTruncated = true }
        case .end:
            box.finish()
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        box.finish(error: "\(error)")
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        box.finish(error: box.flow.status == nil ? "The server closed the connection without answering." : nil)
        context.fireChannelInactive()
    }
}
