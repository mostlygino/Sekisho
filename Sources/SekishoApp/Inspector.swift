import AppKit
import SekishoCore
import SwiftUI

/// The selected request, under the list.
struct Inspector: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let f = store.selectedFlow {
            FlowDetail(flow: f).id(f.id)
        } else {
            Text(store.selection.count > 1 ? "\(store.selection.count) requests selected" : "Select a request to read it")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.raised)
        }
    }
}

enum InspectorLayout: String { case sideBySide, stacked }

/// One request and its response, with what you can do to it on top. The inspector and the request window both use it.
struct FlowDetail: View {
    let flow: Flow
    var standalone = false
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage("inspectorLayout") private var layout: InspectorLayout = .sideBySide
    @State private var maximised: MessagePane.Side?
    @State private var editing: Flow?
    @State private var shotApplied = false
    /// Below 620 pt request goes above response (a tiled window, a small screen).
    @State private var width: CGFloat = 1200

    var body: some View {
        VStack(spacing: 0) {
            actions
            Rectangle().fill(Color.rule).frame(height: 1)
            if flow.kind == .tunnel {
                EncryptedPanel(flow: flow)
            } else if let side = maximised {
                MessagePane(flow: flow, side: side, maximised: $maximised)
            } else if layout == .sideBySide, width >= 620 {
                SideBySide {
                    MessagePane(flow: flow, side: .request, maximised: $maximised)
                } right: {
                    MessagePane(flow: flow, side: .response, maximised: $maximised)
                }
            } else {
                VSplitView {
                    MessagePane(flow: flow, side: .request, maximised: $maximised).frame(minHeight: 140)
                    MessagePane(flow: flow, side: .response, maximised: $maximised).frame(minHeight: 140)
                }
            }
        }
        .background(Color.raised)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear {
            if !shotApplied, let m = store.shotMaximise { maximised = m == "request" ? .request : .response; shotApplied = true }
        }
        .sheet(item: $editing) { request in
            ComposeSheet(request: request) { id in if standalone { openWindow(id: "flow", value: id) } }
        }
    }

    private var actions: some View {
        // Titles when the whole bar fits, icons alone when the window is narrow (tooltips keep the names). The choice
        // wraps the bar, not just the buttons: beside a Spacer a ViewThatFits takes its widest child.
        ViewThatFits(in: .horizontal) {
            actionBar(iconOnly: false)
            actionBar(iconOnly: true)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ground)
    }

    private func actionBar(iconOnly: Bool) -> some View {
        HStack(spacing: 4) {
            if standalone {
                Text(flow.kind == .tunnel ? "CONNECT" : flow.method).font(.system(.callout, design: .monospaced).weight(.semibold))
                Text(flow.url).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: 360, alignment: .leading)
                    .padding(.trailing, 8)
            }
            flowActions(iconOnly: iconOnly)
            Spacer(minLength: 8)
            if flow.kind != .tunnel, width >= 620 {
                Picker("Layout", selection: $layout) {
                    Image(systemName: "rectangle.split.2x1").help("Request and response side by side").tag(InspectorLayout.sideBySide)
                    Image(systemName: "rectangle.split.1x2").help("Request above response").tag(InspectorLayout.stacked)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if !standalone {
                Button { openWindow(id: "flow", value: flow.id) } label: { Image(systemName: "macwindow.on.rectangle") }
                    .buttonStyle(.borderless)
                    .help("Open in its own window (double-click a row)")
            }
        }
    }

    @ViewBuilder private func flowActions(iconOnly: Bool) -> some View {
        let style = iconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon)
        if flow.kind == .http {
            action(style, "Repeat", "arrow.clockwise", "Send it again (⌘R)") { store.repeatRequests([flow]) }
            action(style, "Edit and Repeat", "square.and.pencil", "Change it and send it (⌥⌘R)") { editing = flow }
            action(style, "Breakpoint", Intervention.hold.symbol, "Hold the next request to this URL, and its response") { store.addBreakpoint(flow) }
            Menu {
                ForEach(CodeLanguage.allCases, id: \.self) { lang in Button(lang.rawValue) { store.copyCode(flow, lang) } }
            } label: { Label("Copy as", systemImage: "terminal").labelStyle(style) }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Copy code that sends this request: cURL, HTTPie, Python, fetch, axios, URLSession, Go")
            action(style, store.compareBase == nil || store.compareBase == flow.id ? "Compare" : "Compare with #\(store.flow(store.compareBase!).map(store.number) ?? store.compareBase!)",
                   "arrow.left.arrow.right.square", "Pick this one, then another request, to see them side by side (⌘Y with two selected)") {
                if let base = store.compareBase, base != flow.id {
                    openWindow(id: "diff", value: DiffPair(a: base, b: flow.id))
                    store.compareBase = nil
                } else {
                    store.compareBase = flow.id
                }
            }
        } else {
            action(style, "Copy URL", "link", "Copy host and port") { store.copy(flow.url) }
        }
    }

    private func action(_ style: AnyLabelStyle, _ title: String, _ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: symbol) }
            .buttonStyle(.borderless)
            .labelStyle(style)
            .padding(.horizontal, 4)
            .help(help)
    }
}

/// HTTPS Sekisho has not decrypted: what that means, and the one click that changes it.
struct EncryptedPanel: View {
    @Environment(Store.self) private var store
    let flow: Flow

    private var parent: String? {
        // ponytail: the last two labels, wrong for co.uk-style suffixes; a public suffix list if that matters.
        let labels = flow.host.split(separator: ".")
        guard labels.count > 2, CertificateAuthority.isIPLiteral(flow.host) == false else { return nil }
        return labels.suffix(2).joined(separator: ".")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    TabletMark(on: store.rules.intercepts(flow.host))
                        .frame(width: 44, height: 44)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.rules.intercepts(flow.host) ? "Decrypting \(flow.host) from now on" : "HTTPS to \(flow.host) is still encrypted")
                            .font(.title3.weight(.semibold))
                        Text(store.rules.intercepts(flow.host)
                             ? "This request went through before you switched it on. Sekisho closed the open connections to \(flow.host), so the app's next request arrives decrypted in the list."
                             : "Sekisho passed this connection through untouched (\(Formats.bytes(flow.bytesUp)) sent, \(Formats.bytes(flow.bytesDown)) received), so there is nothing to read yet. Decrypt the host to see every request and response.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !store.caTrusted {
                    Label("Apps will refuse decrypted connections until this Mac trusts Sekisho's certificate.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusClient)
                    Button("Trust Certificate…") { store.installCertificate() }
                }
                if !store.rules.intercepts(flow.host) {
                    HStack(spacing: 10) {
                        Button("Decrypt \(flow.host)") { store.enableSSL(flow.host) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut("d", modifiers: [.command, .option])
                        if let parent { Button("Decrypt *.\(parent)") { store.enableSSL("*." + parent) } }
                        Button("Decrypt All HTTPS") { store.enableSSL("*") }
                    }
                    Text("Apps that pin their certificates refuse Sekisho's and stop working for a decrypted host; switch it off again from the sidebar or Tools > SSL Proxying.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = flow.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A request in its own window: double-click a row, or the window button in the inspector.
struct FlowWindow: View {
    @Environment(Store.self) private var store
    let id: Int?

    var body: some View {
        Group {
            if let id, let f = store.flow(id) {
                FlowDetail(flow: f, standalone: true).navigationTitle("\(f.kind == .tunnel ? "CONNECT" : f.method) \(f.host)")
            } else {
                Text("This request was cleared.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

struct MessagePane: View {
    enum Side { case request, response }
    enum Tab: String, CaseIterable, Identifiable {
        case headers = "Headers", query = "Query", body = "Body", form = "Form", cookies = "Cookies", auth = "Auth"
        case raw = "Raw", messages = "Messages", summary = "Summary"
        var id: String { rawValue }
    }
    enum BodyMode: String, CaseIterable, Identifiable {
        case pretty = "Pretty", tree = "Tree", text = "Text", hex = "Hex", preview = "Preview"
        var id: String { rawValue }
    }

    let flow: Flow
    let side: Side
    var maximised: Binding<Side?>?
    @State private var tab: Tab = .headers
    @State private var mode: BodyMode = .pretty
    @Environment(Store.self) private var store

    private var tabs: [Tab] {
        if side == .request {
            var t: [Tab] = [.headers, .query, .body]
            let type = (flow.requestHeader("Content-Type") ?? "").lowercased()
            if type.contains("x-www-form-urlencoded") || type.contains("multipart") { t.append(.form) }
            t.append(.cookies)
            if flow.requestHeader("Authorization") != nil { t.append(.auth) }
            return t + [.raw]
        }
        return flow.kind == .upgrade ? [.headers, .messages, .raw, .summary] : [.headers, .body, .cookies, .raw, .summary]
    }

    var body: some View {
        VStack(spacing: 0) {
            // One line always: segmented tabs when the whole row fits, a compact menu when it does not. The choice wraps
            // the row: a ViewThatFits beside a Spacer always takes its widest child and pushes the pane wider.
            ViewThatFits(in: .horizontal) {
                headerRow { tabPicker }
                headerRow { tabMenu }
            }
            .frame(height: 26)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Rectangle().fill(Color.rule).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.raised)
        .onAppear {
            if let t = (side == .request ? store.shotRequestTab : store.shotResponseTab).flatMap(Tab.init(rawValue:)), tabs.contains(t) { tab = t }
            if let m = store.shotBodyMode.flatMap(BodyMode.init(rawValue:)) { mode = m }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(tabs) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    private func headerRow(@ViewBuilder tabs: () -> some View) -> some View {
        HStack(spacing: 10) {
            title.fixedSize()
            Spacer(minLength: 8)
            tabs()
            maximiseButton
        }
    }

    private var tabMenu: some View {
        Picker("", selection: $tab) {
            ForEach(tabs) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder private var maximiseButton: some View {
        if let maximised {
            Button { maximised.wrappedValue = maximised.wrappedValue == nil ? side : nil } label: {
                Image(systemName: maximised.wrappedValue == nil ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderless)
            .help(maximised.wrappedValue == nil ? "Give the \(side == .request ? "request" : "response") the whole width" : "Show request and response")
        }
    }

    @ViewBuilder private var title: some View {
        switch side {
        case .request:
            HStack(spacing: 6) {
                Text("Request").font(.headline)
                if let from = flow.mappedFrom {
                    Image(systemName: Intervention.mapRemote.symbol).foregroundStyle(Color.remoteBlue).help("Map Remote: was \(from)")
                }
            }
        case .response:
            HStack(spacing: 6) {
                Text("Response").font(.headline)
                if flow.status != nil || flow.error != nil { StatusCell(flow: flow) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if flow.kind == .tunnel {
            note(side == .request
                 ? "HTTPS to \(flow.host) passes through encrypted. Enable SSL Proxying for this host to read it."
                 : "\(Formats.bytes(flow.bytesUp)) sent, \(Formats.bytes(flow.bytesDown)) received.\(flow.error.map { "\n\($0)" } ?? "")")
        } else if side == .response && flow.status == nil && tab != .summary {
            note(flow.error ?? (flow.interventions.contains(.hold) ? "Held at a breakpoint." : "Waiting for the server…"))
        } else {
            switch tab {
            case .headers: HeaderList(headers: headers, error: side == .response ? flow.error : nil)
            case .body: bodyView
            case .form: FormView(flow: flow)
            case .auth: AuthView(value: flow.requestHeader("Authorization") ?? "")
            case .messages: MessagesView(flow: flow)
            case .summary: SummaryView(flow: flow)
            case .raw: TextView(text: side == .request ? flow.rawRequest : flow.rawResponse)
            case .query: PairList(pairs: flow.queryItems.map { ($0.name, $0.value ?? "") }, empty: "No query parameters")
            case .cookies:
                if side == .request {
                    PairList(pairs: flow.requestCookies, empty: "No cookies sent")
                } else {
                    PairList(pairs: flow.responseCookies.map { cookie in
                        let pair = cookie.split(separator: "=", maxSplits: 1)
                        return (String(pair.first ?? ""), pair.count > 1 ? String(pair[1]) : "")
                    }, empty: "No cookies set")
                }
            }
        }
    }

    private var headers: [Flow.Header] { side == .request ? flow.requestHeaders : flow.responseHeaders }

    @ViewBuilder private var bodyView: some View {
        let raw = side == .request ? flow.requestBody : flow.responseBody
        let decoded = side == .request ? flow.decodedRequestBody : flow.decodedResponseBody
        let data = decoded ?? raw
        let type = (side == .request ? flow.requestHeader("Content-Type") : flow.responseHeader("Content-Type"))?.lowercased() ?? ""
        let json = data.count < 16 << 20 ? JSONValue.parse(data) : nil
        let isHTML = type.contains("html"), image = type.hasPrefix("image/") ? NSImage(data: data) : nil
        let modes = BodyMode.allCases.filter { m in
            switch m {
            case .tree: json != nil
            case .preview: isHTML || image != nil
            default: true
            }
        }
        let current = modes.contains(mode) ? mode : (image != nil ? .preview : .pretty)
        VStack(spacing: 0) {
            if data.isEmpty {
                note("No body")
            } else {
                switch current {
                case .tree: JSONTreeView(root: JSONNode.build(json!))
                case .preview:
                    if let image {
                        ScrollView([.horizontal, .vertical]) { Image(nsImage: image).padding(16) }
                    } else {
                        HTMLPreview(html: String(decoding: data, as: UTF8.self))
                    }
                case .hex: TextView(text: BodyText.hexDump(data))
                case .text: TextView(text: String(data: data, encoding: .utf8) ?? BodyText.hexDump(data))
                case .pretty:
                    if let json = BodyText.prettyJSON(data) { TextView(text: json, highlight: .json) }
                    else if let text = String(data: data, encoding: .utf8) { TextView(text: text) }
                    else if let image { ScrollView([.horizontal, .vertical]) { Image(nsImage: image).padding(16) } }
                    else { TextView(text: BodyText.hexDump(data)) }
                }
            }
            HStack(spacing: 10) {
                Text(caption(raw: raw, decoded: decoded)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Picker("", selection: Binding(get: { current }, set: { mode = $0 })) {
                    ForEach(modes) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("How to show the body. Preview renders HTML with JavaScript and network loads off.")
                Button("Copy") { Store.shared.copy(String(data: data, encoding: .utf8) ?? BodyText.hexDump(data)) }
                Button("Save…") { save(data) }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func caption(raw: Data, decoded: Data?) -> String {
        var parts = [Formats.bytes(raw.count)]
        let encoding = side == .request ? flow.requestHeader("Content-Encoding") : flow.responseHeader("Content-Encoding")
        if let encoding, decoded != nil, decoded != raw { parts.append("\(encoding), \(Formats.bytes(decoded!.count)) decoded") }
        if let encoding, decoded == nil { parts.append("\(encoding) (cannot decode, shown as is)") }
        if side == .response, flow.responseTruncated { parts.append("first \(Formats.bytes(Flow.captureLimit)) kept of \(Formats.bytes(flow.responseSize))") }
        return parts.joined(separator: " · ")
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (URL(string: flow.url)?.lastPathComponent).flatMap { $0.isEmpty || $0 == "/" ? nil : $0 } ?? "body"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(14).textSelection(.enabled)
    }
}

struct HeaderList: View {
    let headers: [Flow.Header]
    var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.holdRed)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                        GridRow {
                            Text(h.name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(h.value).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PairList: View {
    let pairs: [(String, String)]
    let empty: String

    var body: some View {
        if pairs.isEmpty {
            Text(empty).foregroundStyle(.secondary).padding(14)
        } else {
            HeaderList(headers: pairs.map { Flow.Header($0.0, $0.1) })
        }
    }
}

/// A read-only, selectable, monospaced text view that stays fast on large bodies (SwiftUI Text does not).
struct TextView: NSViewRepresentable {
    enum Highlight { case none, json }
    let text: String
    var highlight: Highlight = .none

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.font = Self.font
        view.textColor = .labelColor
        view.isAutomaticLinkDetectionEnabled = false
        view.selectedTextAttributes = [.backgroundColor: NSColor(Color.brass).withAlphaComponent(0.28)]
        scroll.drawsBackground = false
        return scroll
    }

    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        // ponytail: shows the first 2 MB of text; Save… has the rest.
        let shown = text.count > 2_000_000 ? String(text.prefix(2_000_000)) + "\n…" : text
        guard view.string != shown || context.coordinator.highlight != highlight else { return }
        context.coordinator.highlight = highlight
        let attributed = NSMutableAttributedString(string: shown, attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
        if highlight == .json, shown.utf16.count < 600_000 { JSONColours.apply(to: attributed) }
        view.textStorage?.setAttributedString(attributed)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var highlight: Highlight? }
}

/// Colours pretty-printed JSON: keys brass, strings green, numbers amber, true/false/null blue, punctuation quiet.
enum JSONColours {
    static func apply(to text: NSMutableAttributedString) {
        let s = text.string.utf16
        let chars = Array(s)
        let key = NSColor(Color.brass), string = NSColor(Color.statusOK), number = NSColor(Color.localAmber)
        let literal = NSColor(Color.remoteBlue), punct = NSColor.secondaryLabelColor
        var i = 0
        func colour(_ start: Int, _ end: Int, _ c: NSColor) { text.addAttribute(.foregroundColor, value: c, range: NSRange(location: start, length: end - start)) }
        while i < chars.count {
            let c = chars[i]
            if c == 0x22 {  // "
                let start = i
                i += 1
                while i < chars.count, chars[i] != 0x22 { if chars[i] == 0x5C { i += 1 }; i += 1 }
                i += 1
                var j = i
                while j < chars.count, chars[j] == 0x20 { j += 1 }
                colour(start, min(i, chars.count), j < chars.count && chars[j] == 0x3A ? key : string)
                continue
            }
            if (0x30...0x39).contains(c) || c == 0x2D {
                let start = i
                while i < chars.count, (0x30...0x39).contains(chars[i]) || [0x2D, 0x2B, 0x2E, 0x65, 0x45].contains(chars[i]) { i += 1 }
                colour(start, i, number)
                continue
            }
            if c == 0x74 || c == 0x66 || c == 0x6E {  // t f n
                let start = i
                while i < chars.count, (0x61...0x7A).contains(chars[i]) { i += 1 }
                colour(start, i, literal)
                continue
            }
            if [0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A].contains(c) { colour(i, i + 1, punct) }
            i += 1
        }
    }
}

/// An editor set into the page: ground-coloured well, hairline rule, a quiet line while it is empty.
struct Editor: View {
    @Binding var text: String
    var placeholder = ""

    var body: some View {
        EditorView(text: $text)
            .background(Color.ground)
            .overlay(alignment: .topLeading) {
                if text.isEmpty, !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.system(size: NSFont.systemFontSize - 1, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.rule, lineWidth: 1))
    }
}

/// Editable monospaced text for breakpoints, Compose, Map Local and scripts.
struct EditorView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isRichText = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.drawsBackground = false
        view.insertionPointColor = NSColor(Color.brass)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.delegate = context.coordinator
        view.string = text
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The binding can point at a different value now (another rule selected): always write to the current one.
        context.coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { text.wrappedValue = view.string }
        }
    }
}

/// Picks a label style at run time (`labelStyle` wants one concrete type).
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(Label($0).labelStyle(style)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Request and response side by side, split at a remembered fraction. Not HSplitView: it takes each pane's ideal
/// width as its minimum, and the panes' segmented tabs then push the window wider than a tiling window manager leaves it.
struct SideBySide<Left: View, Right: View>: View {
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right
    @AppStorage("paneFraction") private var fraction = 0.5
    @State private var width: CGFloat = 800
    @State private var dragStart: Double?

    var body: some View {
        let leftWidth = min(max(220, width * fraction), max(220, width - 221))
        HStack(spacing: 0) {
            left.frame(width: leftWidth)
            Rectangle()
                .fill(Color.rule)
                .frame(width: 1)
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? fraction
                        dragStart = start
                        fraction = min(max(0.2, start + value.translation.width / max(width, 1)), 0.8)
                    }
                    .onEnded { _ in dragStart = nil })
                .padding(.horizontal, -3)
                .accessibilityHidden(true)
            right.frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
