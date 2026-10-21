import Foundation
import JavaScriptCore

/// Runs Scripting rules on JavaScriptCore, with Proxyman's function shapes so scripts port:
/// `onRequest(context, url, request)` and `onResponse(context, url, request, response)`, each returning the object.
///
/// One JSContext per rule (rebuilt when its code changes), all on one serial queue, sharing `context.sharedState`.
/// ponytail: JavaScriptCore has no public way to stop a runaway script; an endless loop blocks every script (not the
/// proxy's other traffic). A worker process per run is the fix if that ever matters.
public final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sekisho.scripts", qos: .userInitiated)
    private let machine = JSVirtualMachine()!
    private var contexts: [UUID: (code: String, context: JSContext)] = [:]
    private var shared: JSValue?
    /// console.log output and script errors, with the rule's name.
    public var log: (@Sendable (String) -> Void)?

    public init() {}

    public func run(_ stage: BreakpointStage, rule: ScriptRule, flow: Flow, done: @escaping @Sendable (Flow) -> Void) {
        queue.async { [self] in done(runNow(stage, rule: rule, flow: flow)) }
    }

    /// Synchronous, for tests and the queue.
    public func runNow(_ stage: BreakpointStage, rule: ScriptRule, flow: Flow) -> Flow {
        guard (stage == .request && rule.request) || (stage == .response && rule.response) else { return flow }
        let ctx = context(for: rule)
        let name = stage == .request ? "onRequest" : "onResponse"
        guard let fn = ctx.objectForKeyedSubscript(name), !fn.isUndefined else { return flow }
        let request = Self.requestValue(flow, in: ctx)
        let context = JSValue(newObjectIn: ctx)!
        context.setObject(shared ?? JSValue(newObjectIn: ctx), forKeyedSubscript: "sharedState" as NSString)
        let args: [Any] = stage == .request ? [context, flow.url, request] : [context, flow.url, request, Self.responseValue(flow, in: ctx)]
        ctx.exception = nil
        let result = fn.call(withArguments: args)
        if let exception = ctx.exception {
            log?("\(rule.name): \(exception)")
            return flow
        }
        guard let result, result.isObject else {
            log?("\(rule.name): \(name) must return the \(stage == .request ? "request" : "response") object")
            return flow
        }
        var out = flow
        if stage == .request {
            Self.apply(request: result, to: &out, original: Self.requestValue(flow, in: ctx))
        } else {
            Self.apply(response: result, to: &out, original: Self.responseValue(flow, in: ctx))
        }
        if out != flow { out.interventions.insert(.script) }
        return out
    }

    private func context(for rule: ScriptRule) -> JSContext {
        if let cached = contexts[rule.id], cached.code == rule.code { return cached.context }
        let ctx = JSContext(virtualMachine: machine)!
        let name = rule.name
        let logger: @convention(block) () -> Void = { [weak self] in
            let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { v -> String in
                v.isObject ? (v.toObject().flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
                    .map { String(decoding: $0, as: UTF8.self) } ?? v.toString()) : v.toString()
            }
            self?.log?("\(name): \(parts.joined(separator: " "))")
        }
        let console = JSValue(newObjectIn: ctx)!
        console.setObject(logger, forKeyedSubscript: "log" as NSString)
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)
        if shared == nil { shared = JSValue(newObjectIn: ctx) }
        ctx.exceptionHandler = { [weak self] _, exception in self?.log?("\(name): \(exception?.toString() ?? "error")") }
        ctx.evaluateScript(rule.code)
        contexts[rule.id] = (rule.code, ctx)
        return ctx
    }

    // MARK: Flow <-> JavaScript

    static func headerObject(_ headers: [Flow.Header], in ctx: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: ctx)!
        for h in headers {
            let existing = object.objectForKeyedSubscript(h.name)
            let value = existing.map { $0.isUndefined ? h.value : "\($0.toString()!), \(h.value)" } ?? h.value
            object.setObject(value, forKeyedSubscript: h.name as NSString)
        }
        return object
    }

    /// JSON as an object, text as a string; a binary body is not given to the script (undefined) and stays as it is.
    static func bodyValue(_ data: Data, contentType: String?, in ctx: JSContext) -> Any {
        if (contentType ?? "").lowercased().contains("json"), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return JSValue(object: object, in: ctx) as Any
        }
        return String(data: data, encoding: .utf8).map { $0 as Any } ?? JSValue(undefinedIn: ctx) as Any
    }

    /// Two JS values compared as JSON (for headers and queries the script may or may not have touched).
    static func json(_ v: JSValue?) -> String {
        guard let v, !v.isUndefined else { return "" }
        return v.context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [v]).toString() ?? ""
    }

    static func requestValue(_ f: Flow, in ctx: JSContext) -> JSValue {
        let r = JSValue(newObjectIn: ctx)!
        let pathOnly = f.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        r.setObject(f.method, forKeyedSubscript: "method" as NSString)
        r.setObject(f.scheme, forKeyedSubscript: "scheme" as NSString)
        r.setObject(f.host, forKeyedSubscript: "host" as NSString)
        r.setObject(f.port, forKeyedSubscript: "port" as NSString)
        r.setObject(pathOnly, forKeyedSubscript: "path" as NSString)
        let queries = JSValue(newObjectIn: ctx)!
        for q in f.queryItems { queries.setObject(q.value ?? "", forKeyedSubscript: q.name as NSString) }
        r.setObject(queries, forKeyedSubscript: "queries" as NSString)
        r.setObject(headerObject(f.requestHeaders, in: ctx), forKeyedSubscript: "headers" as NSString)
        r.setObject(bodyValue(f.decodedRequestBody ?? f.requestBody, contentType: f.requestHeader("Content-Type"), in: ctx),
                    forKeyedSubscript: "body" as NSString)
        return r
    }

    static func responseValue(_ f: Flow, in ctx: JSContext) -> JSValue {
        let r = JSValue(newObjectIn: ctx)!
        r.setObject(f.status ?? 0, forKeyedSubscript: "statusCode" as NSString)
        r.setObject(headerObject(f.responseHeaders, in: ctx), forKeyedSubscript: "headers" as NSString)
        r.setObject(bodyValue(f.decodedResponseBody ?? f.responseBody, contentType: f.responseHeader("Content-Type"), in: ctx),
                    forKeyedSubscript: "body" as NSString)
        return r
    }

    static func headers(from value: JSValue?) -> [Flow.Header]? {
        guard let value, value.isObject, let dict = value.toDictionary() else { return nil }
        // JavaScript keeps insertion order for string keys; toDictionary does not, so ask for the keys in order.
        let keys = (value.context.objectForKeyedSubscript("Object").invokeMethod("keys", withArguments: [value]).toArray() as? [String]) ?? []
        return keys.compactMap { k in dict[k].map { Flow.Header(k, "\($0)") } }
    }

    /// A body back from JavaScript: objects and arrays as JSON, strings as UTF-8; nil leaves it alone.
    static func body(from value: JSValue?) -> Data? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isString { return Data(value.toString().utf8) }
        if let object = value.toObject(), JSONSerialization.isValidJSONObject(object) {
            return try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        }
        return Data(value.toString().utf8)
    }

    /// Only what the script changed is written back: untouched headers keep their order and repeats (Set-Cookie),
    /// an untouched query keeps its exact encoding, an untouched or binary body keeps its bytes.
    static func apply(request r: JSValue, to f: inout Flow, original o: JSValue) {
        if let m = r.forProperty("method"), m.isString { f.method = m.toString().uppercased() }
        if let s = r.forProperty("scheme"), s.isString, ["http", "https"].contains(s.toString().lowercased()) { f.scheme = s.toString().lowercased() }
        let oldAuthority = f.authority
        if let h = r.forProperty("host"), h.isString, !h.toString().isEmpty { f.host = h.toString() }
        if let p = r.forProperty("port"), p.isNumber, (1...65535).contains(Int(p.toInt32())) { f.port = Int(p.toInt32()) }
        let parts = f.path.split(separator: "?", maxSplits: 1).map(String.init)
        var path = parts.first ?? "/", query = parts.count > 1 ? parts[1] : nil
        if let p = r.forProperty("path"), p.isString, p.toString() != path { path = p.toString() }
        if json(r.forProperty("queries")) != json(o.forProperty("queries")), let q = r.forProperty("queries"), q.isObject,
           let keys = q.context.objectForKeyedSubscript("Object").invokeMethod("keys", withArguments: [q]).toArray() as? [String] {
            var c = URLComponents()
            c.queryItems = keys.map { URLQueryItem(name: $0, value: q.forProperty($0).toString()) }
            query = keys.isEmpty ? nil : c.percentEncodedQuery
        }
        f.path = path + (query.map { "?" + $0 } ?? "")
        if json(r.forProperty("headers")) != json(o.forProperty("headers")), let headers = headers(from: r.forProperty("headers")) {
            f.requestHeaders = headers
        } else if f.authority != oldAuthority {
            // The script moved the request but left Host alone: Host follows, as with Map Remote.
            f.requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Host") == .orderedSame }
            f.requestHeaders.insert(Flow.Header("Host", f.authority), at: 0)
        }
        if json(r.forProperty("body")) != json(o.forProperty("body")), let body = body(from: r.forProperty("body")) {
            f.requestBody = body
            f.requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
        }
    }

    static func apply(response r: JSValue, to f: inout Flow, original o: JSValue) {
        if let s = r.forProperty("statusCode"), s.isNumber, (100...599).contains(Int(s.toInt32())) {
            let code = Int(s.toInt32())
            if code != f.status { f.reason = HTTPURLResponse.localizedString(forStatusCode: code).capitalized }
            f.status = code
        }
        if json(r.forProperty("headers")) != json(o.forProperty("headers")), let headers = headers(from: r.forProperty("headers")) {
            f.responseHeaders = headers
        }
        if json(r.forProperty("body")) != json(o.forProperty("body")), let body = body(from: r.forProperty("body")) {
            f.responseBody = body
            f.responseSize = body.count
            f.responseHeaders.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
        }
    }

    /// Equal bytes, or equal JSON (key order is not kept through JavaScript).
    static func same(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        guard let x = try? JSONSerialization.jsonObject(with: a, options: [.fragmentsAllowed]),
              let y = try? JSONSerialization.jsonObject(with: b, options: [.fragmentsAllowed]) else { return false }
        return (x as AnyObject).isEqual(y)
    }

    /// The body as it would come back unchanged (JSON re-serialised the same way), to tell edits from round trips.
    static func bodyValueData(_ data: Data, contentType: String?) -> Data {
        if (contentType ?? "").lowercased().contains("json"), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           JSONSerialization.isValidJSONObject(object), let again = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) {
            return again
        }
        return data
    }
}
