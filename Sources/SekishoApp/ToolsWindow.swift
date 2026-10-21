import SekishoCore
import SwiftUI
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable {
    case ssl = "SSL Proxying", allow = "Allow List", block = "Block List", breakpoints = "Breakpoints", scripting = "Scripting"
    case mapLocal = "Map Local", mapRemote = "Map Remote", dns = "DNS Spoofing", throttle = "Network Conditions"
    case noCaching = "No Caching", reverse = "Reverse Proxy"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .ssl: "lock.open"
        case .allow: "checkmark.circle"
        case .breakpoints: Intervention.hold.symbol
        case .scripting: Intervention.script.symbol
        case .mapLocal: Intervention.mapLocal.symbol
        case .mapRemote: Intervention.mapRemote.symbol
        case .dns: Intervention.spoofed.symbol
        case .throttle: Intervention.throttled.symbol
        case .block: Intervention.block.symbol
        case .noCaching: "arrow.triangle.2.circlepath"
        case .reverse: "arrow.left.arrow.right"
        }
    }
    var color: Color {
        switch self {
        case .ssl, .allow, .noCaching, .reverse: .brass
        case .breakpoints, .block: .holdRed
        case .mapLocal, .scripting, .throttle: .localAmber
        case .mapRemote, .dns: .remoteBlue
        }
    }
    var explanation: String {
        switch self {
        case .ssl: "HTTPS to these hosts is decrypted with Sekisho's certificate. Everything else passes through as an encrypted tunnel. Patterns: example.com, *.example.com, or * for every host. Excluded hosts are never decrypted."
        case .allow: "When this list has hosts, only they are recorded and decrypted; everything else still works but passes through unseen. Empty: record everything."
        case .breakpoints: "Matching requests stop before they leave, responses before the app gets them, so you can edit or abort them. Patterns match the whole URL: api.example.com, https://api.example.com/v1/*."
        case .scripting: "JavaScript that changes matching requests and responses, in Proxyman's shape: onRequest(context, url, request) and onResponse(context, url, request, response). console.log goes to the log below. A script that loops forever stalls every script until Sekisho restarts."
        case .mapLocal: "Matching requests are answered by Sekisho with this status and body, a file, or a folder (a missing file in the folder goes to the server)."
        case .mapRemote: "Matching requests go to another server. Parts left out of the destination (path, port) are kept."
        case .dns: "Connect to another address for a host, keeping its name in the Host header and in TLS. For staging servers and hosts-file tricks without editing /etc/hosts."
        case .throttle: "Slow matching traffic down: a delay before each request and a bandwidth cap each way, to see how an app behaves on a bad network."
        case .block: "Requests to these hosts are refused with 403 and never leave this Mac."
        case .noCaching: "Every request reaches the server: conditional headers (If-None-Match, If-Modified-Since) are removed and responses are marked no-store."
        case .reverse: "Listens on a local port and forwards everything to a server, recording it. Point an app at http://127.0.0.1:<port> instead of the server."
        }
    }
}

extension Tool {
    var empty: String {
        switch self {
        case .breakpoints: "No breakpoints yet."
        case .scripting: "No scripts yet."
        case .dns: "No DNS overrides yet."
        case .throttle: "No network conditions yet."
        case .reverse: "No reverse proxies yet."
        default: "No \(rawValue) rules yet."
        }
    }

    /// Sidebar groups: what gets recorded, what gets changed, how the network behaves.
    static let groups: [(String, [Tool])] = [
        ("Capture", [.ssl, .allow, .block, .noCaching]),
        ("Change", [.breakpoints, .scripting, .mapLocal, .mapRemote]),
        ("Network", [.dns, .throttle, .reverse]),
    ]
}

/// Every rule on a numbered tablet, bright when on, tarnished when off.
struct ToolsWindow: View {
    @Environment(Store.self) private var store
    @State private var tool: Tool = .ssl
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: Binding(get: { tool }, set: { if let t = $0 { tool = t } })) {
                ForEach(Tool.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { t in
                            Label { Text(t.rawValue).badge(count(t)) } icon: { Image(systemName: t.symbol).foregroundStyle(t.color) }
                                .tag(t)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                ToolHeader(tool: tool)
                Rectangle().fill(Color.rule).frame(height: 1)
                Group {
                    switch tool {
                    case .ssl:
                        HostRules(lists: [
                            .init(title: "Decrypt", keyPath: \.sslProxying, color: .brass, placeholder: "*.example.com"),
                            .init(title: "Never decrypt", keyPath: \.sslExclude, color: .holdRed, placeholder: "bank.example.com"),
                        ])
                    case .allow: HostRules(lists: [.init(title: "Record only", keyPath: \.allowList, color: .brass, placeholder: "api.example.com")])
                    case .block: HostRules(lists: [.init(title: "Block", keyPath: \.blocked, color: .holdRed, placeholder: "ads.example.com")], hideBlocked: true)
                    case .breakpoints: BreakpointRules()
                    case .scripting: ScriptRules()
                    case .mapLocal: MapLocalRules()
                    case .mapRemote: MapRemoteRules()
                    case .dns: DNSRules()
                    case .throttle: ThrottleRules()
                    case .noCaching: NoCaching()
                    case .reverse: ReverseRules()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Tools")
            .background(Color.raised)
        }
        .onAppear { takeRequest() }
        .onChange(of: store.requestedTool) { takeRequest() }
    }

    private func takeRequest() {
        if let t = store.requestedTool { tool = t; store.requestedTool = nil }
    }

    private func count(_ t: Tool) -> Int {
        let r = store.rules
        switch t {
        case .ssl: return r.sslProxying.count
        case .allow: return r.allowList.count
        case .block: return r.blocked.count
        case .breakpoints: return r.breakpoints.filter(\.enabled).count
        case .scripting: return r.scripts.filter(\.enabled).count
        case .mapLocal: return r.mapLocal.filter(\.enabled).count
        case .mapRemote: return r.mapRemote.filter(\.enabled).count
        case .dns: return r.dnsSpoofing.filter(\.enabled).count
        case .throttle: return r.throttles.filter(\.enabled).count
        case .noCaching: return r.noCaching ? 1 : 0
        case .reverse: return r.reverseProxies.filter(\.enabled).count
        }
    }
}

/// The tool's name, its enamel colour and what it does, above its rules.
private struct ToolHeader: View {
    let tool: Tool
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: tool.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tool.color)
                .frame(width: 36, height: 36)
                .background(tool.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tool.color.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.rawValue).font(.title3.weight(.semibold))
                Text(tool.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

/// A list of rules, or, while it has none, a quiet invitation to add the first.
private struct RuleList<Rows: View>: View {
    let tool: Tool
    let isEmpty: Bool
    let add: () -> Void
    var selection: Binding<UUID?>? = nil
    @ViewBuilder let rows: Rows

    var body: some View {
        if isEmpty {
            VStack(spacing: 12) {
                Image(systemName: tool.symbol).font(.system(size: 28, weight: .light)).foregroundStyle(tool.color.opacity(0.75))
                Text(tool.empty).foregroundStyle(.secondary)
                Button("Add Rule", systemImage: "plus", action: add).controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                Group {
                    if let selection { List(selection: selection) { rows } } else { List { rows } }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .scrollContentBackground(.hidden)
                AddBar(add: add)
            }
        }
    }
}

private struct AddBar: View {
    let add: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.rule).frame(height: 1)
            HStack {
                Button("Add Rule", systemImage: "plus", action: add)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

/// The on switch every rule row starts with, after its tablet.
private struct RuleSwitch: View {
    @Binding var on: Bool
    var body: some View { Toggle("On", isOn: $on).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
}

private struct RemoveButton: View {
    let remove: () -> Void
    var body: some View {
        Button(action: remove) { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Remove")
            .accessibilityLabel("Remove rule")
    }
}

struct HostRules: View {
    struct HostList {
        let title: String
        let keyPath: WritableKeyPath<ProxyRules, [String]>
        let color: Color
        let placeholder: String
    }

    @Environment(Store.self) private var store
    let lists: [HostList]
    var hideBlocked = false
    @State private var drafts: [String: String] = [:]

    var body: some View {
        @Bindable var store = store
        Form {
            if hideBlocked {
                Section { Toggle("Hide blocked requests from the list", isOn: $store.rules.hideBlocked) }
            }
            ForEach(lists, id: \.title) { list in
                Section(list.title) {
                    ForEach(Array(store.rules[keyPath: list.keyPath].enumerated()), id: \.offset) { i, host in
                        HStack(spacing: 10) {
                            TabletPlate(number: i + 1, mark: list.color, on: true)
                            Text(host).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            RemoveButton { store.rules[keyPath: list.keyPath].remove(at: i) }
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "plus").foregroundStyle(.tertiary).frame(width: 20)
                        TextField("Host", text: draft(list.title), prompt: Text(list.placeholder))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { add(list) }
                        Button("Add") { add(list) }.disabled((drafts[list.title] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func draft(_ key: String) -> Binding<String> {
        Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })
    }

    private func add(_ list: HostList) {
        let host = (drafts[list.title] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return }
        if !store.rules[keyPath: list.keyPath].contains(host) { store.rules[keyPath: list.keyPath].append(host) }
        drafts[list.title] = ""
    }
}

struct NoCaching: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("No Caching", isOn: $store.rules.noCaching).toggleStyle(.switch)
            } footer: {
                Text("Applies to every request Sekisho decrypts or sees in plain HTTP.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct BreakpointRules: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        RuleList(tool: .breakpoints, isEmpty: store.rules.breakpoints.isEmpty, add: { store.rules.breakpoints.append(BreakpointRule(pattern: "api.example.com")) }) {
            ForEach(Array($store.rules.breakpoints.enumerated()), id: \.element.id) { i, $rule in
                HStack(spacing: 10) {
                    TabletPlate(number: i + 1, mark: .holdRed, on: rule.enabled)
                    RuleSwitch(on: $rule.enabled)
                    TextField("Method", text: $rule.method, prompt: Text("Any"))
                        .labelsHidden().frame(width: 64).font(.system(.body, design: .monospaced))
                    TextField("URL pattern", text: $rule.pattern).labelsHidden().font(.system(.body, design: .monospaced))
                    Toggle("Request", isOn: $rule.request).fixedSize()
                    Toggle("Response", isOn: $rule.response).fixedSize()
                    RemoveButton { store.rules.breakpoints.remove(at: i) }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

struct MapRemoteRules: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        RuleList(tool: .mapRemote, isEmpty: store.rules.mapRemote.isEmpty,
                 add: { store.rules.mapRemote.append(MapRemoteRule(pattern: "https://api.example.com/*", destination: "http://localhost:3000")) }) {
            ForEach(Array($store.rules.mapRemote.enumerated()), id: \.element.id) { i, $rule in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TabletPlate(number: i + 1, mark: .remoteBlue, on: rule.enabled)
                    RuleSwitch(on: $rule.enabled)
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("From") { TextField("From", text: $rule.pattern).labelsHidden().font(.system(.body, design: .monospaced)) }
                        LabeledContent("To") { TextField("To", text: $rule.destination).labelsHidden().font(.system(.body, design: .monospaced)) }
                        Toggle("Keep the original Host header", isOn: $rule.preserveHost)
                    }
                    RemoveButton { store.rules.mapRemote.remove(at: i) }
                }
                .padding(.vertical, 5)
            }
        }
    }
}

struct MapLocalRules: View {
    @Environment(Store.self) private var store
    @State private var selected: UUID?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            RuleList(tool: .mapLocal, isEmpty: store.rules.mapLocal.isEmpty, add: add, selection: $selected) {
                ForEach(Array($store.rules.mapLocal.enumerated()), id: \.element.id) { i, $rule in
                    HStack(spacing: 10) {
                        TabletPlate(number: i + 1, mark: .localAmber, on: rule.enabled)
                        RuleSwitch(on: $rule.enabled)
                        Text(rule.pattern).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(rule.directory != nil ? "Folder" : rule.filePath != nil ? "File" : String(rule.status))
                            .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        RemoveButton { store.rules.mapLocal.remove(at: i) }
                    }
                    .tag(rule.id)
                }
            }
            .frame(height: store.rules.mapLocal.isEmpty ? nil : 170)
            if let i = store.rules.mapLocal.firstIndex(where: { $0.id == selected }) {
                MapLocalEditor(rule: $store.rules.mapLocal[i]).id(store.rules.mapLocal[i].id)
            }
        }
        .onAppear { if selected == nil { selected = store.rules.mapLocal.first?.id } }
    }

    private func add() {
        let rule = MapLocalRule(pattern: "https://api.example.com/v1/*", body: "{\n  \"ok\": true\n}")
        store.rules.mapLocal.append(rule)
        selected = rule.id
    }
}

struct MapLocalEditor: View {
    @Binding var rule: MapLocalRule

    var body: some View {
        Form {
            Section("Rule") {
                TextField("URL pattern", text: $rule.pattern).font(.system(.body, design: .monospaced))
                TextField("Status", value: $rule.status, format: .number.grouping(.never))
                TextField("Content-Type", text: $rule.contentType).font(.system(.body, design: .monospaced))
            }
            Section("Answer with") {
            HStack {
                Text(rule.directory.map { "Folder: \($0)" } ?? rule.filePath.map { "File: \($0)" } ?? "The body below")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if rule.filePath != nil || rule.directory != nil { Button("Use Text Body") { rule.filePath = nil; rule.directory = nil } }
                Button("Choose Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { rule.directory = url.path; rule.filePath = nil }
                }
                Button("Choose File…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        rule.directory = nil
                        rule.filePath = url.path
                        if let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType { rule.contentType = type }
                    }
                }
            }
            if rule.filePath == nil && rule.directory == nil {
                Editor(text: $rule.body, placeholder: "Response body").frame(minHeight: 160)
            }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 260)
    }
}

struct DNSRules: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        RuleList(tool: .dns, isEmpty: store.rules.dnsSpoofing.isEmpty, add: { store.rules.dnsSpoofing.append(DNSRule(host: "api.example.com", address: "127.0.0.1")) }) {
            ForEach(Array($store.rules.dnsSpoofing.enumerated()), id: \.element.id) { i, $rule in
                HStack(spacing: 10) {
                    TabletPlate(number: i + 1, mark: .remoteBlue, on: rule.enabled)
                    RuleSwitch(on: $rule.enabled)
                    TextField("Host", text: $rule.host).labelsHidden().font(.system(.body, design: .monospaced))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Address", text: $rule.address).labelsHidden().font(.system(.body, design: .monospaced))
                    RemoveButton { store.rules.dnsSpoofing.remove(at: i) }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

struct ThrottleRules: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        RuleList(tool: .throttle, isEmpty: store.rules.throttles.isEmpty,
                 add: { store.rules.throttles.append(ThrottleRule(pattern: "*", latencyMs: 300, downKbps: 780, upKbps: 330)) }) {
            ForEach(Array($store.rules.throttles.enumerated()), id: \.element.id) { i, $rule in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TabletPlate(number: i + 1, mark: .localAmber, on: rule.enabled)
                    RuleSwitch(on: $rule.enabled)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            TextField("URL pattern", text: $rule.pattern).labelsHidden().font(.system(.body, design: .monospaced))
                            Menu("Preset") {
                                ForEach(ThrottleRule.presets, id: \.name) { p in
                                    Button(p.name) { rule.latencyMs = p.latency; rule.downKbps = p.down; rule.upKbps = p.up }
                                }
                            }
                            .fixedSize()
                        }
                        HStack(spacing: 14) {
                            field("Delay", "ms", $rule.latencyMs, help: "Delay before each request, in milliseconds")
                            field("Down", "kbps", $rule.downKbps, help: "Download cap in kilobits per second; 0 is no cap")
                            field("Up", "kbps", $rule.upKbps, help: "Upload cap in kilobits per second; 0 is no cap")
                        }
                    }
                    RemoveButton { store.rules.throttles.remove(at: i) }
                }
                .padding(.vertical, 5)
            }
        }
    }

    private func field(_ label: String, _ unit: String, _ value: Binding<Int>, help: String) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.grouping(.never))
                .labelsHidden().frame(width: 62).multilineTextAlignment(.trailing).monospacedDigit()
            Text(unit).foregroundStyle(.tertiary).font(.caption)
        }
        .help(help)
    }
}

struct ReverseRules: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        RuleList(tool: .reverse, isEmpty: store.rules.reverseProxies.isEmpty,
                 add: { store.rules.reverseProxies.append(ReverseProxyRule(localPort: 8888, remoteHost: "api.example.com", remotePort: 443, tls: true)) }) {
            ForEach(Array($store.rules.reverseProxies.enumerated()), id: \.element.id) { i, $rule in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TabletPlate(number: i + 1, mark: .brass, on: rule.enabled)
                    RuleSwitch(on: $rule.enabled)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Text("Listen on").foregroundStyle(.secondary)
                            Text("127.0.0.1:").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                            TextField("Local port", value: $rule.localPort, format: .number.grouping(.never))
                                .labelsHidden().frame(width: 64).font(.system(.body, design: .monospaced))
                        }
                        HStack(spacing: 6) {
                            Text("Forward to").foregroundStyle(.secondary)
                            Picker("Scheme", selection: $rule.tls) { Text("http").tag(false); Text("https").tag(true) }.labelsHidden().fixedSize()
                            TextField("Host", text: $rule.remoteHost).labelsHidden().font(.system(.body, design: .monospaced))
                            Text(":").foregroundStyle(.secondary)
                            TextField("Port", value: $rule.remotePort, format: .number.grouping(.never))
                                .labelsHidden().frame(width: 64).font(.system(.body, design: .monospaced))
                        }
                        if let error = store.reverseErrors[rule.id] {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.holdRed).font(.callout)
                        }
                    }
                    RemoveButton { store.rules.reverseProxies.remove(at: i) }
                }
                .padding(.vertical, 5)
            }
        }
    }
}

struct ScriptRules: View {
    @Environment(Store.self) private var store
    @State private var selected: UUID?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            RuleList(tool: .scripting, isEmpty: store.rules.scripts.isEmpty, add: add, selection: $selected) {
                ForEach(Array($store.rules.scripts.enumerated()), id: \.element.id) { i, $rule in
                    HStack(spacing: 10) {
                        TabletPlate(number: i + 1, mark: .localAmber, on: rule.enabled)
                        RuleSwitch(on: $rule.enabled)
                        TextField("Name", text: $rule.name).labelsHidden().frame(width: 130)
                        TextField("URL pattern", text: $rule.pattern).labelsHidden().font(.system(.body, design: .monospaced))
                        Toggle("Request", isOn: $rule.request).fixedSize()
                        Toggle("Response", isOn: $rule.response).fixedSize()
                        RemoveButton { store.rules.scripts.remove(at: i) }
                    }
                    .tag(rule.id)
                }
            }
            .frame(height: store.rules.scripts.isEmpty ? nil : 150)
            if let i = store.rules.scripts.firstIndex(where: { $0.id == selected }) {
                Rectangle().fill(Color.rule).frame(height: 1)
                ScriptEditor(rule: $store.rules.scripts[i]).id(store.rules.scripts[i].id).frame(minHeight: 200)
            }
            if !store.rules.scripts.isEmpty {
                Rectangle().fill(Color.rule).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Console").font(.headline)
                        Spacer()
                        Button("Clear") { store.scriptLog.removeAll() }.controlSize(.small).disabled(store.scriptLog.isEmpty)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    if store.scriptLog.isEmpty {
                        Text("console.log output appears here.").foregroundStyle(.tertiary).font(.callout)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TextView(text: store.scriptLog.joined(separator: "\n"))
                    }
                }
                .frame(height: 120)
            }
        }
        .onAppear { if selected == nil { selected = store.rules.scripts.first?.id } }
    }

    private func add() {
        let rule = ScriptRule(pattern: "api.example.com", name: "Script \(store.rules.scripts.count + 1)")
        store.rules.scripts.append(rule)
        selected = rule.id
    }
}

/// The code of one script. Applied when you stop typing for a moment, so a half-typed script never runs.
struct ScriptEditor: View {
    @Binding var rule: ScriptRule
    @State private var draft = ""
    @State private var save: Task<Void, Never>?

    var body: some View {
        EditorView(text: $draft)
            .onAppear { draft = rule.code }
            .onChange(of: draft) { _, text in
                save?.cancel()
                save = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    if !Task.isCancelled { rule.code = text }
                }
            }
    }
}
