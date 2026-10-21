import AppKit
import SekishoCore
import SwiftUI
import WebKit

// MARK: JSON tree

struct JSONNode: Identifiable {
    /// Unique in the tree (duplicate keys are legal JSON); `path` is the readable key path.
    let id: String
    var path: String
    let key: String
    let value: String
    /// What Copy Value puts on the pasteboard: a string's decoded text, everything else as shown.
    var copy: String
    let tint: Color
    var children: [JSONNode]?

    /// ponytail: at most 1,000 children per node and 60 levels; a "…" row says what was left out.
    static func build(_ value: JSONValue, key: String = "root", id: String = "$", path: String = "$", depth: Int = 0) -> JSONNode {
        func node(_ v: String, _ tint: Color, copy: String? = nil) -> JSONNode {
            JSONNode(id: id, path: path, key: key, value: v, copy: copy ?? v, tint: tint)
        }
        func more(_ count: Int) -> JSONNode { JSONNode(id: id + "…", path: path, key: "…", value: "\(count - 1_000) more", copy: "", tint: .secondary) }
        switch value {
        case .object(let members):
            var n = node(members.isEmpty ? "{}" : "{ \(members.count) \(members.count == 1 ? "key" : "keys") }", .secondary, copy: value.pretty())
            if depth < 60, !members.isEmpty {
                n.children = members.prefix(1_000).enumerated().map { i, m in
                    build(m.value, key: m.key, id: id + "/\(i)", path: path + (m.key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? "." + m.key : "[" + JSONValue.quote(m.key) + "]"), depth: depth + 1)
                }
                if members.count > 1_000 { n.children!.append(more(members.count)) }
            }
            return n
        case .array(let items):
            var n = node(items.isEmpty ? "[]" : "[ \(items.count) \(items.count == 1 ? "item" : "items") ]", .secondary, copy: value.pretty())
            if depth < 60, !items.isEmpty {
                n.children = items.prefix(1_000).enumerated().map { build($1, key: "\($0)", id: id + "/\($0)", path: path + "[\($0)]", depth: depth + 1) }
                if items.count > 1_000 { n.children!.append(more(items.count)) }
            }
            return n
        case .string(let text, let raw): return node(raw, .statusOK, copy: text)
        case .number(let n): return node(n, .localAmber)
        case .bool(let b): return node(b ? "true" : "false", .remoteBlue)
        case .null: return node("null", .remoteBlue)
        }
    }
}

struct JSONTreeView: View {
    let root: JSONNode
    @State private var copied: String?

    var body: some View {
        List {
            OutlineGroup(root.children ?? [root], children: \.children) { node in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(node.key).foregroundStyle(Color.brass)
                    Text(node.value).foregroundStyle(node.tint).lineLimit(3).textSelection(.enabled)
                }
                .font(.system(.body, design: .monospaced))
                .contextMenu {
                    Button("Copy Value") { Store.shared.copy(node.copy) }
                    Button("Copy Key Path") { Store.shared.copy(node.path) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: Forms

struct FormView: View {
    let flow: Flow

    var body: some View {
        let type = flow.requestHeader("Content-Type") ?? ""
        let data = flow.decodedRequestBody ?? flow.requestBody
        if type.lowercased().contains("multipart") {
            let parts = FormParser.multipart(data, contentType: type)
            if parts.isEmpty {
                Text("No parts found in this multipart body.").foregroundStyle(.secondary).padding(14)
            } else {
                Table(parts) {
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("File") { Text($0.filename ?? "") }
                    TableColumn("Type") { Text($0.contentType ?? "text").foregroundStyle(.secondary) }
                    TableColumn("Size") { Text(Formats.bytes($0.body.count)).monospacedDigit() }
                    TableColumn("Value") { p in
                        Text(p.filename == nil ? String(decoding: p.body.prefix(200), as: UTF8.self) : "")
                            .lineLimit(1).font(.system(.body, design: .monospaced))
                    }
                }
                .contextMenu(forSelectionType: Int.self) { ids in
                    if let p = parts.first(where: { ids.contains($0.id) }) {
                        Button("Save Part…") {
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = p.filename ?? (p.name.isEmpty ? "part" : p.name)
                            if panel.runModal() == .OK, let url = panel.url { try? p.body.write(to: url) }
                        }
                    }
                }
            }
        } else {
            PairList(pairs: FormParser.urlEncoded(data), empty: "No form fields")
        }
    }
}

// MARK: Auth

struct AuthView: View {
    let value: String
    @State private var reveal = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
                let scheme = parts.first ?? "", credential = parts.count > 1 ? parts[1] : ""
                LabeledContent("Scheme") { Text(scheme).font(.system(.body, design: .monospaced)) }
                switch scheme.lowercased() {
                case "basic":
                    let decoded = Data(base64Encoded: credential).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let pair = decoded.split(separator: ":", maxSplits: 1).map(String.init)
                    LabeledContent("User") { Text(pair.first ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    LabeledContent("Password") {
                        HStack {
                            Text(reveal ? (pair.count > 1 ? pair[1] : "") : "••••••••").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Button(reveal ? "Hide" : "Show") { reveal.toggle() }.controlSize(.small)
                        }
                    }
                case "bearer" where credential.split(separator: ".").count == 3:
                    let segments = credential.split(separator: ".").map(String.init)
                    Text("JSON Web Token").font(.headline)
                    jwtSection("Header", segments[0])
                    jwtSection("Payload", segments[1])
                    if let payload = Self.decode(segments[1]) as? [String: Any] {
                        ForEach(["exp", "iat", "nbf"], id: \.self) { k in
                            if let t = payload[k] as? Double {
                                LabeledContent(k == "exp" ? "Expires" : k == "iat" ? "Issued" : "Not before") {
                                    let date = Date(timeIntervalSince1970: t)
                                    Text(date.formatted(date: .abbreviated, time: .standard) + (k == "exp" && date < Date() ? "  (expired)" : ""))
                                }
                            }
                        }
                    }
                    LabeledContent("Signature") { Text("\(segments[2].count) characters, not verified").foregroundStyle(.secondary) }
                default:
                    LabeledContent("Credential") { Text(credential).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func jwtSection(_ title: String, _ segment: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(Self.decode(segment).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }
                .map { String(decoding: $0, as: UTF8.self) } ?? "(not JSON)")
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    static func decode(_ segment: String) -> Any? {
        var s = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
}

// MARK: Summary

struct SummaryView: View {
    @Environment(Store.self) private var store
    let flow: Flow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("URL", flow.url)
                    if let from = flow.mappedFrom { row("Mapped from", from) }
                    row("Method", flow.kind == .tunnel ? "CONNECT" : flow.method)
                    row("Status", flow.status.map { "\($0) \(flow.reason)" } ?? (flow.error ?? "Waiting"))
                    if let app = store.app(for: flow) { row("Client", "\(app.name) (pid \(app.pid))") }
                    row("Connection", flow.connection.map { "#\($0)" } ?? "")
                    row("Started", flow.started.formatted(date: .abbreviated, time: .standard))
                    row("Request", "\(Formats.bytes(headerBytes(flow.requestHeaders))) headers, \(Formats.bytes(flow.requestBody.count)) body")
                    row("Response", "\(Formats.bytes(headerBytes(flow.responseHeaders))) headers, \(Formats.bytes(flow.responseSize)) body"
                        + (flow.decodedResponseBody.map { $0.count != flow.responseBody.count ? ", \(Formats.bytes($0.count)) decoded" : "" } ?? ""))
                    if !flow.interventions.isEmpty {
                        row("Changed by Sekisho", Intervention.order.filter { flow.interventions.contains($0) }.map(\.label).joined(separator: ", "))
                    }
                }
                if let phases = phases, let total = flow.duration, total > 0 {
                    Text("Timing").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(phases, id: \.0) { name, start, length in
                            GridRow {
                                Text(name).foregroundStyle(.secondary).fixedSize()
                                GeometryReader { geo in
                                    Capsule().fill(brassGradient)
                                        .frame(width: max(2, geo.size.width * CGFloat(length / total)), height: 8)
                                        .offset(x: geo.size.width * CGFloat(start / total), y: 4)
                                }
                                .frame(minWidth: 80, maxWidth: 320).frame(height: 16)
                                Text(Formats.duration(length)).monospacedDigit().font(.system(.body, design: .monospaced)).fixedSize()
                            }
                        }
                        GridRow {
                            Text("Total").fontWeight(.semibold).fixedSize()
                            Color.clear.frame(minWidth: 80, maxWidth: 320).frame(height: 1)
                            Text(Formats.duration(total)).monospacedDigit().font(.system(.body, design: .monospaced)).fontWeight(.semibold).fixedSize()
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func headerBytes(_ headers: [Flow.Header]) -> Int { headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 } }

    /// (phase, start offset, length) in seconds from the start of the exchange.
    private var phases: [(String, Double, Double)]? {
        let t = flow.timing, s = flow.started
        guard let connectStart = t.connectStart else { return nil }
        var out: [(String, Double, Double)] = []
        func add(_ name: String, _ a: Date?, _ b: Date?) {
            if let a, let b, b >= a { out.append((name, a.timeIntervalSince(s), b.timeIntervalSince(a))) }
        }
        add("Before", s, connectStart)
        add("Connect", connectStart, t.connected)
        add("TLS", t.connected, t.secured)
        add("Send", t.secured ?? t.connected, t.sent)
        add("Wait", t.sent, t.firstByte)
        add("Receive", t.firstByte, flow.ended)
        return out
    }
}

// MARK: HTML preview

/// Renders captured HTML with JavaScript off and every network load blocked: a page must not phone home from Sekisho.
struct HTMLPreview: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "sekisho-block-all", encodedContentRuleList: rules) { list, _ in
            guard let list else { return }  // No rule list, no preview: never load without it.
            view.configuration.userContentController.add(list)
            view.loadHTMLString(html, baseURL: nil)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Only the initial load of the captured page; links do nothing.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other && (action.request.url?.absoluteString ?? "about:blank").hasPrefix("about:") ? .allow : .cancel)
        }
    }
}

// MARK: WebSocket messages

/// "1000 normal closure" from a close frame's payload.
private func closeReason(_ payload: Data) -> String {
    guard payload.count >= 2 else { return "closed" }
    let code = Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])
    let reason = String(decoding: payload.dropFirst(2), as: UTF8.self)
    let name = [1000: "normal", 1001: "going away", 1002: "protocol error", 1006: "abnormal", 1008: "policy", 1011: "server error"][code] ?? ""
    return ([String(code), name, reason].filter { !$0.isEmpty }).joined(separator: " · ")
}

struct MessagesView: View {
    let flow: Flow
    @State private var selected: Int?

    var body: some View {
        if flow.messages.isEmpty {
            Text(flow.status == 101 ? "No messages yet." : "The upgrade has not gone through.").foregroundStyle(.secondary).padding(14)
        } else {
            VSplitView {
                Table(flow.messages, selection: $selected) {
                    TableColumn("") { m in
                        Image(systemName: m.direction == .sent ? "arrow.up" : "arrow.down")
                            .foregroundStyle(m.direction == .sent ? Color.brass : Color.statusOK)
                    }
                    .width(18)
                    TableColumn("Time") { Text(Formats.time.string(from: $0.time)).monospacedDigit().font(.system(.body, design: .monospaced)) }
                        .width(min: 100, ideal: 110)
                    TableColumn("Kind") { Text($0.kind.rawValue) }.width(min: 50, ideal: 60)
                    TableColumn("Size") { Text(Formats.bytes($0.length)).monospacedDigit() }.width(min: 50, ideal: 70)
                    TableColumn("Data") { m in
                        Text(m.kind == .text ? String(decoding: m.payload.prefix(300), as: UTF8.self)
                             : m.kind == .close ? closeReason(m.payload) : m.payload.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
                            .lineLimit(1).font(.system(.callout, design: .monospaced))
                            .foregroundStyle(m.kind == .text ? .primary : .secondary)
                    }
                    .width(min: 160, ideal: 420)
                }
                .alternatingRowBackgrounds(.disabled)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .onAppear { if selected == nil { selected = flow.messages.first { $0.kind == .text }?.id } }
                if let id = selected, let m = flow.messages.first(where: { $0.id == id }) {
                    TextView(text: m.kind == .text ? (BodyText.prettyJSON(m.payload) ?? String(decoding: m.payload, as: UTF8.self)) : BodyText.hexDump(m.payload))
                        .frame(minHeight: 100)
                }
            }
        }
    }
}
