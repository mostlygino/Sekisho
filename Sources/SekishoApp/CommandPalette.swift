import AppKit
import SekishoCore
import SwiftUI

/// ⌘K: one floating field for every action, tool, host, app and request, from any Sekisho window.
/// Same shape as Kekkai's and Shīru's: a non-activating glass panel in the upper third of the screen.
@MainActor
final class CommandPalette: NSObject, NSWindowDelegate {
    static let shared = CommandPalette()

    private var panel: PalettePanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : show() }

    func show(query: String = "") {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: PaletteView.width, height: 440),
                                 styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.title = "Command Palette"
        panel.contentView = NSHostingView(rootView: PaletteView(close: { [weak self] in self?.close() }, initialQuery: query)
            .environment(Store.shared)
            .tint(.brassFill))

        // Upper third of the screen the user is working on, like Spotlight.
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - PaletteView.width / 2, y: frame.maxY - frame.height * 0.18))
        }
        self.panel?.close()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        focusField(in: panel)
    }

    /// SwiftUI's focus request can land before the hosting view is in the panel, so the cursor goes into
    /// the search field from AppKit as well.
    private func focusField(in panel: NSPanel) {
        DispatchQueue.main.async {
            guard let field = Self.textField(in: panel.contentView) else { return }
            panel.makeFirstResponder(field)
        }
    }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(textField(in:)).first
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

/// Borderless panels refuse key status by default; this one takes typing.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Window actions the palette can't reach through the environment (it lives in its own panel).
/// The main window fills these in.
@MainActor
enum PaletteActions {
    static var openWindow: ((String) -> Void)?
    static var openFlow: ((Int) -> Void)?
    static var openDiff: ((DiffPair) -> Void)?
    static var openSettings: (() -> Void)?
}

// MARK: Items

struct PaletteItem: Identifiable {
    enum Icon { case symbol(String, Color? = nil), app(ClientApp), flow(Flow) }
    enum Group: Int { case suggested, typed, actions, tools, filters, hosts, apps, requests }

    let id: String
    let title: String
    var subtitle: String?
    let icon: Icon
    var shortcut: String?
    var keywords: [String] = []
    let group: Group
    let run: () -> Void
    /// ⌘Return: the second thing you most often want (decrypt a host, open a request in its own window).
    var alternate: (label: String, run: () -> Void)?
    /// ⌥Return: the third (block a host, repeat a request).
    var option: (label: String, run: () -> Void)?
}

/// Fuzzy match: prefix beats word start beats substring beats letters in order.
enum PaletteSearch {
    static func score(_ query: String, in candidates: [String]) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        return candidates.compactMap { score(q, $0.lowercased()) }.max()
    }

    static func score(_ q: String, _ text: String) -> Int? {
        if text.hasPrefix(q) { return 1000 - text.count }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 800 - text.count }
        if text.contains(q) { return 600 - text.count }
        // Letters in order, fewer gaps first ("dcrall" finds "Decrypt All HTTPS").
        var gaps = 0, index = text.startIndex
        for ch in q {
            guard let found = text[index...].firstIndex(of: ch) else { return nil }
            gaps += text.distance(from: index, to: found)
            index = text.index(after: found)
        }
        return max(1, 400 - gaps * 10 - text.count)
    }
}

@MainActor
enum PaletteCatalog {
    static func items(query: String, store: Store) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let actions = actionItems(store: store)

        guard !trimmed.isEmpty else {
            // Before typing: what people open this for, then the newest requests.
            let suggested = ["system-proxy", "decrypt-all", "compose", "record", "tools", "trust"]
            let top = suggested.compactMap { id in actions.first { $0.id == id } }.map { a -> PaletteItem in
                var item = PaletteItem(id: a.id, title: a.title, subtitle: a.subtitle, icon: a.icon, shortcut: a.shortcut, group: .suggested, run: a.run)
                item.alternate = a.alternate
                return item
            }
            let recent = store.flows.suffix(5).reversed().map { flowItem($0, store: store) }
            return top + recent
        }

        // "#12" jumps straight to a request.
        // "#3" is the number shown in the list (imported sessions are numbered from 1 too).
        if trimmed.hasPrefix("#"), let n = Int(trimmed.dropFirst()) {
            let matches = store.flows.filter { store.number($0) == n }
            if !matches.isEmpty { return matches.map { flowItem($0, store: store) } }
        }

        let candidates = actions + toolItems(store: store) + filterItems(store: store)
            + store.domainGroups.map { hostItem($0.host, count: $0.count, store: store) }
            + store.appGroups.map { appItem($0.app, count: $0.count, store: store) }
        // The title counts most; keywords and the subtitle only break ties.
        var scored = candidates.compactMap { item -> (item: PaletteItem, score: Int)? in
            let title = PaletteSearch.score(trimmed, in: [item.title]).map { $0 + 200 }
            let other = PaletteSearch.score(trimmed, in: item.keywords + [item.subtitle ?? ""])
            return [title, other].compactMap { $0 }.max().map { (item, $0) }
        }
        // Requests: newest first, matched on URL, method and status; at most 25.
        let needle = trimmed.lowercased()
        let flows = store.flows.reversed().lazy.filter {
            $0.url.lowercased().contains(needle) || $0.method.lowercased() == needle || $0.status.map { String($0) == needle } == true
        }.prefix(25)
        scored += flows.map { (flowItem($0, store: store), 300) }
        // One section per group, the group with the best match first.
        let best = Dictionary(scored.map { ($0.item.group, $0.score) }, uniquingKeysWith: max)
        let results = scored.sorted {
            let (a, b) = (best[$0.item.group] ?? 0, best[$1.item.group] ?? 0)
            return a != b ? a > b : $0.score > $1.score
        }.map(\.item).prefix(70)
        return typedItems(trimmed, store: store) + Array(results)
    }

    /// Typed a URL, a curl command or a host: offer the obvious thing to do with it.
    private static func typedItems(_ text: String, store: Store) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if text.hasPrefix("curl "), let f = Import.curl(text) {
            items.append(PaletteItem(id: "typed-curl", title: "Compose This curl Command", subtitle: "\(f.method) \(f.url)",
                                     icon: .symbol("terminal", .brass), group: .typed) { store.composing = f })
        } else if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            var f = Flow.blank
            if f.setURL(text) {
                f.requestHeaders = [Flow.Header("Accept", "*/*")]
                items.append(PaletteItem(id: "typed-get", title: "Send GET \(f.url)", subtitle: "Straight to the server, recorded in the list",
                                         icon: .symbol("paperplane", .brass), group: .typed) { store.send(f) })
                items.append(PaletteItem(id: "typed-compose", title: "Compose a Request to \(f.host)", subtitle: f.url,
                                         icon: .symbol("square.and.pencil"), group: .typed) { store.composing = f })
            }
        } else if text.contains("."), !text.contains(" "), Flow.isValidHost(text.lowercased()) {
            let host = text.lowercased()
            if !store.rules.intercepts(host) {
                items.append(PaletteItem(id: "typed-decrypt", title: "Decrypt “\(host)”", subtitle: "Add it to the SSL Proxying list",
                                         icon: .symbol("lock.open", .brass), group: .typed) { store.enableSSL(host) })
            }
            if !store.rules.blocked.contains(host) {
                items.append(PaletteItem(id: "typed-block", title: "Block “\(host)”", subtitle: "Refuse it with 403",
                                         icon: .symbol(Intervention.block.symbol, .holdRed), group: .typed) { store.toggleBlock(host) })
            }
            items.append(PaletteItem(id: "typed-breakpoint", title: "Breakpoint on “\(host)”", subtitle: "Hold its requests and responses",
                                     icon: .symbol(Intervention.hold.symbol, .holdRed), group: .typed) {
                store.rules.breakpoints.append(BreakpointRule(pattern: host, request: true, response: true))
            })
        }
        return items
    }

    private static func actionItems(store: Store) -> [PaletteItem] {
        let selected = store.selectedFlows
        var items: [PaletteItem] = [
            PaletteItem(id: "system-proxy", title: store.systemProxyOn ? "Turn Off macOS Proxy" : "Turn On macOS Proxy",
                        subtitle: store.systemProxyOn ? "Put the previous proxy settings back" : "Send this Mac's web traffic through Sekisho",
                        icon: .symbol("point.3.connected.trianglepath.dotted", store.systemProxyOn ? .brass : nil), shortcut: "⇧⌘P",
                        keywords: ["system", "network", "start", "stop", "on", "off"], group: .actions) {
                store.setSystemProxy(!store.systemProxyOn)
            },
            PaletteItem(id: "decrypt-all", title: store.decryptsAll ? "Decrypt Only the Listed Hosts" : "Decrypt All HTTPS",
                        subtitle: store.decryptsAll ? "Stop decrypting every host" : "Read every HTTPS request, not only listed hosts",
                        icon: .symbol(store.decryptsAll ? "lock.open.fill" : "lock", .brass),
                        keywords: ["ssl", "tls", "https", "proxying", "mitm"], group: .actions) {
                store.decryptsAll.toggle()
            },
            PaletteItem(id: "record", title: store.recording ? "Pause Recording" : "Resume Recording",
                        subtitle: store.recording ? "Traffic keeps flowing; new requests are not listed" : "List new requests again",
                        icon: .symbol(store.recording ? "pause.circle" : "record.circle", store.recording ? nil : .statusFailed), shortcut: "⌘P", keywords: ["record", "pause", "capture"], group: .actions) {
                store.recording.toggle()
            },
            PaletteItem(id: "compose", title: "Compose Request…", icon: .symbol("square.and.pencil"), shortcut: "⌘N",
                        keywords: ["new", "send", "request", "postman"], group: .actions) { store.composing = .blank },
            PaletteItem(id: "open", title: "Open Session or HAR…", icon: .symbol("folder"), shortcut: "⌘O",
                        keywords: ["import", "har", "load", "file"], group: .actions) { store.openFile() },
            PaletteItem(id: "save", title: "Save Session…", subtitle: "\(store.visibleFlows.count) requests as a .sekisho file",
                        icon: .symbol("square.and.arrow.down"), shortcut: "⌘S", keywords: ["export", "store", "file"], group: .actions) {
                store.saveSession(store.visibleFlows)
            },
            PaletteItem(id: "har", title: "Export Visible as HAR…", icon: .symbol("square.and.arrow.up"), shortcut: "⇧⌘E",
                        keywords: ["export", "har", "archive"], group: .actions) { store.exportHAR(store.visibleFlows) },
            PaletteItem(id: "clear", title: "Clear the List", subtitle: "\(store.flows.count) requests", icon: .symbol("trash"), shortcut: "⇧⌘K",
                        keywords: ["delete", "empty", "reset"], group: .actions) { store.clear() },
            PaletteItem(id: "tools", title: "Open Tools", icon: .symbol("slider.horizontal.3"), shortcut: "⇧⌘T",
                        keywords: ["rules", "breakpoints", "map", "script"], group: .actions) { PaletteActions.openWindow?("tools") },
            PaletteItem(id: "settings", title: "Settings…", icon: .symbol("gearshape"), shortcut: "⌘,",
                        keywords: ["preferences", "port", "certificate", "network", "upstream"], group: .actions) { PaletteActions.openSettings?() },
            PaletteItem(id: "welcome", title: "Welcome to Sekisho", subtitle: "The setup walk: certificate, traffic, decrypting",
                        icon: .symbol("signpost.right"), keywords: ["onboarding", "setup", "getting started", "help", "tour"], group: .actions) {
                PaletteActions.openWindow?("welcome")
            },
            PaletteItem(id: "about", title: "About Sekisho", icon: .symbol("info.circle"), keywords: ["version", "build", "credits"], group: .actions) {
                PaletteActions.openWindow?("about")
            },
            PaletteItem(id: "simulator", title: "Install Certificate in iOS Simulators", icon: .symbol("iphone"),
                        keywords: ["ios", "simctl", "xcode", "certificate"], group: .actions) { store.installInSimulators() },
        ]
        if !store.caTrusted {
            items.insert(PaletteItem(id: "trust", title: "Trust Sekisho's Certificate…", subtitle: "Needed to read HTTPS; macOS asks for your password",
                                     icon: .symbol("checkmark.seal", .statusClient), keywords: ["certificate", "keychain", "ca"], group: .actions) {
                store.installCertificate()
            }, at: 0)
        }
        if let f = selected.first, selected.count == 1, f.kind == .http {
            items += [
                PaletteItem(id: "sel-repeat", title: "Repeat #\(store.number(f))", subtitle: "\(f.method) \(f.url)", icon: .symbol("arrow.clockwise"),
                            shortcut: "⌘R", keywords: ["again", "replay", "resend"], group: .actions) { store.repeatRequests([f]) },
                PaletteItem(id: "sel-edit", title: "Edit and Repeat #\(store.number(f))…", icon: .symbol("square.and.pencil"), shortcut: "⌥⌘R",
                            keywords: ["edit", "change", "resend"], group: .actions) { store.composing = f },
                PaletteItem(id: "sel-curl", title: "Copy #\(store.number(f)) as cURL", icon: .symbol("terminal"), shortcut: "⌥⌘C",
                            keywords: ["copy", "curl", "shell"], group: .actions) { store.copyCurl([f]) },
                PaletteItem(id: "sel-window", title: "Open #\(store.number(f)) in Its Own Window", icon: .symbol("macwindow.on.rectangle"),
                            keywords: ["enlarge", "big", "window", "detail"], group: .actions) { PaletteActions.openFlow?(f.id) },
            ]
            items += CodeLanguage.allCases.filter { $0 != .curl }.map { lang in
                PaletteItem(id: "sel-code-\(lang.rawValue)", title: "Copy #\(store.number(f)) as \(lang.rawValue)", icon: .symbol("chevron.left.forwardslash.chevron.right"),
                            keywords: ["copy", "code", "snippet"], group: .actions) { store.copyCode(f, lang) }
            }
        }
        if selected.count == 2 {
            items.append(PaletteItem(id: "sel-compare", title: "Compare #\(store.number(selected[0])) and #\(store.number(selected[1]))", icon: .symbol("arrow.left.arrow.right.square"),
                                     shortcut: "⌘Y", keywords: ["diff", "compare"], group: .actions) {
                PaletteActions.openDiff?(DiffPair(a: selected[0].id, b: selected[1].id))
            })
        }
        return items
    }

    private static func toolItems(store: Store) -> [PaletteItem] {
        Tool.allCases.map { tool in
            PaletteItem(id: "tool-\(tool.rawValue)", title: tool.rawValue, subtitle: tool.explanation, icon: .symbol(tool.symbol, tool.color),
                        keywords: ["tool", "rules"], group: .tools) {
                store.requestedTool = tool
                PaletteActions.openWindow?("tools")
            }
        }
    }

    private static func filterItems(store: Store) -> [PaletteItem] {
        let kinds = ["HTTP", "HTTPS"] + Flow.Category.allCases.map(\.rawValue)
        return kinds.map { k in
            PaletteItem(id: "filter-\(k)", title: "Show Only \(k)", icon: .symbol("line.3.horizontal.decrease.circle"),
                        keywords: ["filter", "only", "show", k.lowercased()], group: .filters) {
                store.chips = [k]; store.statusChips = []
            }
        } + (1...5).map { c in
            PaletteItem(id: "filter-\(c)xx", title: "Show Only \(c)xx Responses", icon: .symbol("line.3.horizontal.decrease.circle"),
                        keywords: ["status", "filter", "error", "\(c)00"], group: .filters) {
                store.statusChips = [c]; store.chips = []
            }
        } + [PaletteItem(id: "filter-none", title: "Show Everything", icon: .symbol("line.3.horizontal.decrease.circle"),
                         keywords: ["clear filter", "all", "reset"], group: .filters) {
            store.chips = []; store.statusChips = []; store.onlyMarked = false; store.filterText = ""; store.sidebar = .all
        }]
    }

    private static func hostItem(_ host: String, count: Int, store: Store) -> PaletteItem {
        let decrypted = store.rules.intercepts(host), blocked = store.rules.blocks(host)
        var item = PaletteItem(
            id: "host-\(host)", title: host,
            subtitle: ["\(count) \(count == 1 ? "request" : "requests")", blocked ? "blocked" : decrypted ? "decrypted" : "encrypted"].joined(separator: " · "),
            icon: .symbol(blocked ? "nosign" : decrypted ? "lock.open.fill" : "lock.fill", blocked ? .holdRed : decrypted ? .brass : nil),
            group: .hosts
        ) { store.sidebar = .domain(host) }
        item.alternate = decrypted && store.rules.sslProxying.contains(host)
            ? ("Stop decrypting", { store.toggleSSLProxying(host) })
            : decrypted ? nil : ("Decrypt", { store.enableSSL(host) })
        item.option = (store.rules.blocked.contains(host) ? "Unblock" : "Block", { store.toggleBlock(host) })
        return item
    }

    private static func appItem(_ app: ClientApp, count: Int, store: Store) -> PaletteItem {
        PaletteItem(id: "app-\(app.key)", title: app.name, subtitle: "\(count) \(count == 1 ? "request" : "requests")",
                    icon: .app(app), keywords: [app.executablePath], group: .apps) { store.sidebar = .app(app.key) }
    }

    private static func flowItem(_ f: Flow, store: Store) -> PaletteItem {
        var item = PaletteItem(
            id: "flow-\(f.id)", title: f.kind == .tunnel ? "\(f.host) (encrypted)" : "\(f.method) \(f.host)\(f.path)",
            subtitle: ["#\(store.number(f))", f.status.map { "\($0) \(f.reason)" } ?? f.error, store.app(for: f)?.name].compactMap { $0 }.joined(separator: " · "),
            icon: .flow(f), group: .requests
        ) {
            store.sidebar = .all
            store.reveal(f.id)
        }
        item.alternate = ("Open in window", { PaletteActions.openFlow?(f.id) })
        if f.kind == .http { item.option = ("Repeat", { store.repeatRequests([f]) }) }
        return item
    }
}

// MARK: View

struct PaletteView: View {
    static let width: CGFloat = 660

    let close: () -> Void
    var initialQuery = ""
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selectedID: String?
    @State private var appeared = false
    @FocusState private var fieldFocused: Bool
    @Namespace private var highlight

    private var items: [PaletteItem] { PaletteCatalog.items(query: query, store: store) }
    private var selected: PaletteItem? { items.first { $0.id == selectedID } ?? items.first }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            field
            if !items.isEmpty {
                Divider().opacity(0.5)
                results(items)
                Divider().opacity(0.5)
                footer
            } else if !query.isEmpty {
                Divider().opacity(0.5)
                Text("Nothing matches “\(query)”. Try a host, an app, a path, #12, a URL, a curl command, or an action such as “decrypt”.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(width: Self.width)
        .modifier(PaletteGlass())
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            query = initialQuery
            fieldFocused = true
            withAnimation(.spring(duration: 0.28, bounce: 0.12)) { appeared = true }
        }
        .onChange(of: query) { selectedID = nil }
        .onExitCommand(perform: close)
    }

    private var field: some View {
        HStack(spacing: 12) {
            TabletMark(on: store.recording && store.running)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                .frame(width: 28, height: 28)
            TextField("Search requests, hosts and actions, or paste a URL", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($fieldFocused)
                .onSubmit { run(selected) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.command), let alt = selected?.alternate { finish(alt.run); return .handled }
                    if press.modifiers.contains(.option), let opt = selected?.option { finish(opt.run); return .handled }
                    return .ignored
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func results(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].group != item.group {
                            groupHeader(item.group).padding(.top, index == 0 ? 6 : 12)
                        }
                        row(item).id(item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 400)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }

    private func groupHeader(_ group: PaletteItem.Group) -> some View {
        let title = switch group {
        case .suggested: "Suggested"
        case .typed: "From What You Typed"
        case .actions: "Actions"
        case .tools: "Tools"
        case .filters: "Filters"
        case .hosts: "Hosts"
        case .apps: "Apps"
        case .requests: "Requests"
        }
        return Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    private func row(_ item: PaletteItem) -> some View {
        let isSelected = item.id == selected?.id
        return HStack(spacing: 12) {
            icon(item.icon, selected: isSelected)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut).font(.callout.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.brass.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.brass.opacity(0.4), lineWidth: 1))
                    .matchedGeometryEffect(id: "highlight", in: highlight)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { run(item) }
        .onHover { if $0 { withAnimation(.snappy(duration: 0.16)) { selectedID = item.id } } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func icon(_ icon: PaletteItem.Icon, selected: Bool) -> some View {
        switch icon {
        case .app(let app):
            Image(nsImage: AppIcons.icon(for: app)).resizable().frame(width: 30, height: 30)
        case .flow(let f):
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(selected ? 0.0 : 0.6))
                VStack(spacing: 1) {
                    Text(f.kind == .tunnel ? "TLS" : String(f.method.prefix(4)))
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    StatusDot(f)
                }
            }
            .frame(width: 30, height: 30)
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint ?? (selected ? Color.brass : .secondary))
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(selected ? 0.0 : 0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↵", selected.map { $0.group == .requests || $0.group == .hosts || $0.group == .apps ? "Show" : "Run" } ?? "Run")
            if let alt = selected?.alternate { hint("⌘↵", alt.label) }
            if let opt = selected?.option { hint("⌥↵", opt.label) }
            Spacer()
            hint("esc", "Close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
        }
    }

    private func move(_ delta: Int) {
        let items = items
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selected?.id } ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        withAnimation(.snappy(duration: 0.16)) { selectedID = items[next].id }
    }

    private func run(_ item: PaletteItem?) {
        guard let item else { return }
        finish(item.run)
    }

    private func finish(_ action: @escaping () -> Void) {
        close()
        NSApp.activate()
        DispatchQueue.main.async(execute: action)
    }
}

/// Liquid Glass over a faint linen ground, so text stays readable on busy desktops.
private struct PaletteGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        content
            .background(Color.ground.opacity(0.6), in: shape)
            .glassEffect(.regular, in: shape)
            .overlay(shape.strokeBorder(Color.brass.opacity(0.22), lineWidth: 1))
    }
}

/// Shows the palette in an ordinary window for 10 seconds, for screenshots: an ordinary window lands where
/// the window manager puts the app's windows, unlike the floating panel that joins every space.
@MainActor
enum PaletteSnapshot {
    static func show(query: String) {
        let view = NSHostingView(rootView: PaletteView(close: {}, initialQuery: query).environment(Store.shared).tint(.brassFill).padding(24))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: PaletteView.width + 48, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Palette Snapshot"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        // Left open in demo mode, for however long a capture takes; otherwise gone after a minute.
        if !Demo.on { DispatchQueue.main.asyncAfter(deadline: .now() + 60) { window.close() } }
    }
}
