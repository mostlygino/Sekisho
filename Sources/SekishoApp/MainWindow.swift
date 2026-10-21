import AppKit
import SekishoCore
import SwiftUI

struct MainWindow: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 360)
        } detail: {
            ListAndInspector()
                .background(Color.ground)
                .safeAreaInset(edge: .top, spacing: 0) { Banners() }
        }
        .searchable(text: $store.filterText, placement: .toolbar, prompt: "Filter URL, method or status")
        .toolbar { MainToolbar() }
        .onAppear {
            // The palette lives in its own panel, outside this environment: give it the window actions.
            PaletteActions.openWindow = { openWindow(id: $0) }
            PaletteActions.openFlow = { openWindow(id: "flow", value: $0) }
            PaletteActions.openDiff = { openWindow(id: "diff", value: $0) }
            PaletteActions.openSettings = { openSettings() }
            // First launch: the setup walk, once. Not in the demo, which has nothing to set up.
            if !Demo.on, !Demo.defaults.bool(forKey: WelcomeWindow.seenKey) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { openWindow(id: "welcome") }
            }
            if let shot = Demo.on ? Demo.shot : UserDefaults.standard.string(forKey: "shot") {
                if !Demo.on { UserDefaults.standard.removeObject(forKey: "shot") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ScreenshotDirector.run(shot, store: store) }
            }
        }
        .onChange(of: store.shotSidebarHidden) { _, hidden in columns = hidden ? .detailOnly : .all }
        .onChange(of: store.pending.count) { old, new in
            if new > old { openWindow(id: "breakpoint") }
        }
        .sheet(item: $store.composing) { request in
            ComposeSheet(request: request)
        }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { store.recording.toggle() } label: {
                RecordControl(recording: store.recording && store.running, inFlight: store.inFlight)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.recording ? "Recording new requests. Click to pause (⌘P)." : "Paused: traffic still flows but new requests are not listed. Click to record (⌘P).")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { store.systemProxyOn }, set: { store.setSystemProxy($0) })) {
                Label("macOS Proxy", systemImage: store.systemProxyOn ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted")
            }
            .disabled(!store.running)
            .help(store.systemProxyOn ? "macOS sends web traffic through Sekisho. Click to put the previous setting back."
                  : "Send this Mac's web traffic through Sekisho (127.0.0.1:\(store.port)).")
            Toggle(isOn: Binding(get: { store.decryptsAll }, set: { store.decryptsAll = $0 })) {
                Label("Decrypt All HTTPS", systemImage: store.decryptsAll ? "lock.open.fill" : "lock")
            }
            .help(store.decryptsAll ? "Every HTTPS host is decrypted. Click to decrypt only the hosts on the SSL Proxying list."
                  : "Decrypt HTTPS for every host, not only those on the SSL Proxying list")
            Button { store.composing = Flow.blank } label: { Label("Compose", systemImage: "square.and.pencil") }
                .help("Build a request and send it (⌘N)")
            Button { openWindow(id: "tools") } label: { Label("Tools", systemImage: "slider.horizontal.3") }
                .help("SSL Proxying, Breakpoints, Map Local, Map Remote, Block List (⇧⌘T)")
            Button { CommandPalette.shared.toggle() } label: { Label("Command Palette", systemImage: "command") }
                .help("Search requests, hosts, apps and every action (⌘K)")
            Button { store.clear() } label: { Label("Clear", systemImage: "trash") }
                .help("Remove every recorded request (⇧⌘K)")
                .disabled(store.flows.isEmpty)
        }
    }
}

extension Flow {
    static var blank: Flow {
        var f = Flow(id: 0)
        f.scheme = "https"; f.host = "example.com"; f.port = 443; f.path = "/"
        f.requestHeaders = [Header("Accept", "*/*")]
        return f
    }
}

/// The list above, request and response below, split at a remembered fraction.
/// (VSplitView cannot be given a starting position and hands the list everything.)
struct ListAndInspector: View {
    @AppStorage("listFraction") private var fraction = 0.46
    @State private var dragStart: Double?
    // Measured, not read from a GeometryReader: under the glass sidebar the detail column has a 240 pt leading safe
    // area, and a GeometryReader there shifted the list sideways and cut it off.
    @State private var height: CGFloat = 800

    var body: some View {
        let listHeight = min(max(140, height * fraction), height - 200)
        VStack(spacing: 0) {
            FilterBar()
            FlowList().frame(height: max(100, listHeight - 30))
            Rectangle()
                .fill(Color.rule)
                .frame(height: 1)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? fraction
                        dragStart = start
                        fraction = min(max(0.15, start + value.translation.height / max(height, 1)), 0.85)
                    }
                    .onEnded { _ in dragStart = nil })
                .accessibilityHidden(true)
            Inspector()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        List(selection: $store.sidebar) {
            Label { Text("All Traffic").badge(store.flows.count) } icon: { Image(systemName: "tray.full") }
                .tag(SidebarItem.all)
            if !store.pinnedRows.isEmpty {
                Section("Pinned") {
                    ForEach(store.pinnedRows, id: \.key) { row in
                        Label { Text(row.title).badge(row.count).lineLimit(1).truncationMode(.middle) } icon: {
                            Image(systemName: "pin.fill").foregroundStyle(Color.brass)
                        }
                        .tag(row.item)
                        .contextMenu { Button("Unpin") { store.togglePin(row.key) } }
                    }
                }
            }
            Section("Apps") {
                ForEach(store.appGroups, id: \.app.key) { group in
                    Label {
                        Text(group.app.name).badge(group.count)
                    } icon: {
                        Image(nsImage: AppIcons.icon(for: group.app)).resizable().frame(width: 16, height: 16)
                    }
                    .tag(SidebarItem.app(group.app.key))
                    .contextMenu { Button(store.pinned.contains(group.app.key) ? "Unpin" : "Pin") { store.togglePin(group.app.key) } }
                }
            }
            Section("Domains") {
                ForEach(store.domainGroups, id: \.host) { group in
                    Label {
                        Text(group.host).badge(group.count).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: icon(for: group.host))
                            .foregroundStyle(store.rules.blocks(group.host) ? Color.holdRed : store.rules.intercepts(group.host) ? Color.brass : .secondary)
                    }
                    .tag(SidebarItem.domain(group.host))
                    .contextMenu { DomainMenu(host: group.host) }
                    .help(store.rules.blocks(group.host) ? "Blocked" : store.rules.intercepts(group.host) ? "SSL Proxying on: HTTPS is decrypted" : "HTTPS passes through encrypted")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { ProxyStatus() }
    }

    private func icon(for host: String) -> String {
        store.rules.blocks(host) ? "nosign" : store.rules.intercepts(host) ? "lock.open.fill" : "lock.fill"
    }
}

struct DomainMenu: View {
    @Environment(Store.self) private var store
    let host: String

    var body: some View {
        Button(store.rules.intercepts(host) && store.rules.sslProxying.contains(host) ? "Stop SSL Proxying" : "Enable SSL Proxying") {
            store.toggleSSLProxying(host)
        }
        Button(store.rules.blocked.contains(host) ? "Unblock" : "Block") { store.toggleBlock(host) }
        Button(store.pinned.contains(host) ? "Unpin" : "Pin") { store.togglePin(host) }
        Divider()
        Button("Copy Host") { store.copy(host) }
    }
}

/// Where Sekisho listens, and whether HTTPS can be read. Pinned under the sidebar.
struct ProxyStatus: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(store.running ? Color.statusOK : Color.holdRed).frame(width: 7, height: 7)
                Text(store.running ? "127.0.0.1:\(String(store.port))" : "Not listening")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .help(store.running ? "Sekisho listens here, on this Mac only." : (store.startError ?? "Not listening"))
            if !store.caTrusted {
                Button { store.installCertificate() } label: {
                    Label("Trust Certificate…", systemImage: "checkmark.seal")
                }
                .controlSize(.small)
                .help("Add Sekisho's CA to your login keychain and trust it, so HTTPS on the SSL Proxying list can be read. macOS asks for your password.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

enum AppIcons {
    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor static func icon(for app: ClientApp) -> NSImage {
        if let cached = cache[app.key] { return cached }
        let path = app.bundlePath ?? app.executablePath
        // A path that is gone (an uninstalled app, a session from another Mac) gets a neutral app glyph, not a blank document.
        let image = FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path)
            : (NSImage(systemSymbolName: app.bundlePath == nil ? "terminal" : "app.dashed", accessibilityDescription: app.name) ?? NSImage())
        cache[app.key] = image
        return image
    }
}

// MARK: Banners

struct Banners: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.startError {
                banner(error, symbol: "exclamationmark.triangle.fill", color: .holdRed, action: ("Try Again", { store.restart() }))
            }
            if let notice = store.notice {
                banner(notice, symbol: "info.circle.fill", color: .secondary, action: ("Dismiss", { store.notice = nil }))
            }
        }
    }

    private func banner(_ text: String, symbol: String, color: Color, action: (String, () -> Void)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action.0, action: action.1).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.rule).frame(height: 1) }
    }
}

// MARK: Flow list

struct FlowList: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var wide = true

    var body: some View {
        @Bindable var store = store
        let rows = store.visibleFlows
        // Order and widths so #, Status, Method, Host and Path fit a 1,000 pt window; the rest is extra.
        // Small minimums: together they set the window's narrowest width, and tiling window managers go narrow.
        // App and Time step aside below 900 pt rather than squeeze every column into "…".
        ScrollViewReader { scroller in
            Table(rows, selection: $store.selection, sortOrder: $store.sortOrder) {
                TableColumn("#", value: \.id) { f in
                    HStack(spacing: 5) {
                        Circle().fill(store.marks[f.id]?.color?.color ?? .clear).frame(width: 6, height: 6)
                        Text(String(store.number(f))).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .width(min: 40, ideal: 50, max: 76)
                TableColumn("Status", value: \.sortStatus) { f in StatusCell(flow: f) }
                    .width(min: 52, ideal: 76, max: 120)
                TableColumn("Method", value: \.method) { f in
                    Text(f.kind == .tunnel ? "CONNECT" : f.method).font(.system(.callout, design: .monospaced).weight(.semibold))
                }
                .width(min: 58, ideal: 74, max: 100)
                TableColumn("Host", value: \.host) { f in
                    Text(f.authority).lineLimit(1).truncationMode(.middle)
                }
                .width(min: 50, ideal: 150)
                TableColumn("Path", value: \.path) { f in
                    let strike = store.marks[f.id]?.strike == true
                    HStack(spacing: 6) {
                        if let op = store.operations[f.id] {
                            Text(op).font(.caption.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.brass.opacity(0.18)))
                                .help("GraphQL operation")
                        }
                        Text(f.kind == .tunnel ? "Encrypted" : f.path)
                            .foregroundStyle(f.kind == .tunnel ? .secondary : .primary)
                            .strikethrough(strike)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .help(f.kind == .tunnel ? "Not decrypted. Select it to decrypt this host." : f.mappedFrom.map { "Map Remote: was \($0)" } ?? f.url)
                }
                .width(min: 64, ideal: 240)
                TableColumn("Tools") { f in
                    HStack(spacing: 4) {
                        ForEach(Intervention.order.filter { f.interventions.contains($0) }, id: \.self) { i in
                            Image(systemName: i.symbol).foregroundStyle(i.color).help(i.label)
                        }
                        if let comment = store.marks[f.id]?.comment, !comment.isEmpty {
                            Image(systemName: "text.bubble").foregroundStyle(.secondary).help(comment)
                        }
                    }
                    .imageScale(.small)
                }
                .width(min: 30, ideal: 48, max: 110)
                TableColumn("Duration", value: \.sortDuration) { f in
                    Text(Formats.duration(f.duration)).font(.system(.callout, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 52, ideal: 70, max: 100)
                TableColumn("Size", value: \.sortSize) { f in
                    Text(f.kind == .http ? (f.status == nil ? "" : Formats.bytes(f.responseSize)) : Formats.bytes(f.bytesDown))
                        .font(.system(.callout, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 52, ideal: 70, max: 100)
                if wide {
                    TableColumn("App") { f in
                        if let app = store.app(for: f) {
                            HStack(spacing: 5) {
                                Image(nsImage: AppIcons.icon(for: app)).resizable().frame(width: 16, height: 16)
                                Text(app.name).lineLimit(1)
                            }
                            .help(app.executablePath)
                        }
                    }
                    .width(min: 60, ideal: 104)
                    TableColumn("Time", value: \.started) { f in
                        Text(Formats.time.string(from: f.started)).font(.system(.callout, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 92, ideal: 104, max: 130)
                }
            }
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)
            .onGeometryChange(for: Bool.self) { $0.size.width >= 900 } action: { wide = $0 }
            .contextMenu(forSelectionType: Int.self) { ids in
                FlowMenu(flows: ids.compactMap(store.flow).sorted { $0.id < $1.id })
            } primaryAction: { ids in
                for id in ids.sorted().prefix(8) { openWindow(id: "flow", value: id) }
            }
            .onDeleteCommand { store.remove(store.selection) }
            .overlay { if store.flows.isEmpty { EmptyState() } }
            .onChange(of: store.scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(nil) { scroller.scrollTo(id, anchor: .center) }
                store.scrollTarget = nil
            }
            .alert("Comment", isPresented: Binding(get: { store.commenting != nil }, set: { if !$0 { store.commenting = nil } })) {
                TextField("Comment", text: $store.commentDraft)
                Button("Save") {
                    if let ids = store.commenting { store.mark(ids) { $0.comment = store.commentDraft } }
                    store.commenting = nil
                }
                Button("Cancel", role: .cancel) { store.commenting = nil }
            } message: {
                Text("Shown in the Tools column and found by the filter.")
            }
        }
    }
}

/// Filter chips over the list: content kinds, then status classes. Click picks one; ⌘-click adds or removes.
/// All chips when they fit; when the window is narrow, the same filters as two compact menus, so nothing is cut off.
struct FilterBar: View {
    @Environment(Store.self) private var store
    static let kinds = ["HTTP", "HTTPS"] + Flow.Category.allCases.map(\.rawValue)

    var body: some View {
        @Bindable var store = store
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                allChip
                separator
                ForEach(Self.kinds, id: \.self) { k in chip(k, on: store.chips.contains(k)) { toggle(&store.chips, k) } }
                separator
                ForEach(1...5, id: \.self) { c in chip("\(c)xx", on: store.statusChips.contains(c)) { toggle(&store.statusChips, c) } }
                separator
                chip("Marked", on: store.onlyMarked) { store.onlyMarked.toggle() }
                Spacer(minLength: 12)
                bodies
            }
            .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 8) {
                allChip
                kindMenu
                statusMenu
                chip("Marked", on: store.onlyMarked) { store.onlyMarked.toggle() }
                Spacer(minLength: 8)
                bodies
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.rule).frame(height: 1) }
    }

    private var separator: some View { Rectangle().fill(Color.rule).frame(width: 1, height: 14).padding(.horizontal, 3) }

    private var allChip: some View {
        chip("All", on: store.chips.isEmpty && store.statusChips.isEmpty && !store.onlyMarked) {
            store.chips.removeAll(); store.statusChips.removeAll(); store.onlyMarked = false
        }
    }

    private var bodies: some View {
        @Bindable var store = store
        return Toggle("Search bodies", isOn: $store.searchBodies)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()
            .help("Also match the filter text inside request and response bodies")
    }

    private var kindMenu: some View {
        Menu {
            ForEach(Self.kinds, id: \.self) { k in
                Toggle(k, isOn: Binding(get: { store.chips.contains(k) }, set: { on in
                    if on { store.chips.insert(k) } else { store.chips.remove(k) }
                }))
            }
        } label: {
            menuLabel(store.chips.isEmpty ? "Kind" : store.chips.sorted().joined(separator: ", "), on: !store.chips.isEmpty)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
    }

    private var statusMenu: some View {
        Menu {
            ForEach(1...5, id: \.self) { c in
                Toggle("\(c)xx", isOn: Binding(get: { store.statusChips.contains(c) }, set: { on in
                    if on { store.statusChips.insert(c) } else { store.statusChips.remove(c) }
                }))
            }
        } label: {
            menuLabel(store.statusChips.isEmpty ? "Status" : store.statusChips.sorted().map { "\($0)xx" }.joined(separator: ", "), on: !store.statusChips.isEmpty)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
    }

    private func menuLabel(_ title: String, on: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 11, weight: on ? .semibold : .regular))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(on ? Color.white : Color.primary)
        .background(Capsule().fill(on ? Color.brassFill : Color.primary.opacity(0.06)))
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if NSEvent.modifierFlags.contains(.command) {
            if set.contains(value) { set.remove(value) } else { set.insert(value) }
        } else {
            set = set == [value] ? [] : [value]
        }
    }

    private func chip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(Capsule().fill(on ? Color.brassFill : Color.primary.opacity(0.06)))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct StatusCell: View {
    let flow: Flow
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(flow)
            Group {
                if flow.blocked { Text("403").monospacedDigit() }
                else if flow.interventions.contains(.aborted) { Text("Aborted") }
                else if flow.error != nil && flow.status == nil { Text("Failed") }
                else if let status = flow.status { Text(String(status)).monospacedDigit() }
                else if flow.kind == .tunnel { Text(flow.ended == nil ? "Open" : "Closed").foregroundStyle(.secondary) }
                else if flow.interventions.contains(.hold) { Text("Held").foregroundStyle(Color.holdRed) }
                else { Text("…").foregroundStyle(.secondary) }
            }
            .font(.system(.body, design: .monospaced))
        }
        .help(flow.error ?? (flow.status.map { "\($0) \(flow.reason)" } ?? ""))
    }
}

struct FlowMenu: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    let flows: [Flow]

    var body: some View {
        let http = flows.filter { $0.kind == .http }
        if let f = flows.first {
            Button("Open in New Window") { for f in flows.prefix(8) { openWindow(id: "flow", value: f.id) } }
            Divider()
            Button("Copy URL") { store.copy(flows.map(\.url).joined(separator: "\n")) }
            Button("Copy as cURL") { store.copyCurl(http) }.disabled(http.isEmpty)
            Menu("Copy as Code") {
                ForEach(CodeLanguage.allCases, id: \.self) { lang in Button(lang.rawValue) { store.copyCode(f, lang) } }
            }
            .disabled(f.kind != .http)
            if flows.count == 2 {
                Button("Compare") { openWindow(id: "diff", value: DiffPair(a: flows[0].id, b: flows[1].id)) }
            }
            Divider()
            Button("Repeat") { store.repeatRequests(http) }.disabled(http.isEmpty)
            Button("Edit and Repeat…") { store.composing = f }.disabled(f.kind != .http)
            Divider()
            Button(store.rules.sslProxying.contains(f.host) ? "Stop SSL Proxying for \(f.host)" : "Enable SSL Proxying for \(f.host)") {
                store.toggleSSLProxying(f.host)
            }
            Button("Breakpoint on This URL") { store.addBreakpoint(f) }.disabled(f.kind != .http)
            Button("Map Local From This Response") { store.addMapLocal(f) }.disabled(f.kind != .http)
            Button("Map Remote…") { store.addMapRemote(f) }
            Button(store.rules.blocked.contains(f.host) ? "Unblock \(f.host)" : "Block \(f.host)") { store.toggleBlock(f.host) }
            Divider()
            Menu("Highlight") {
                ForEach(MarkColor.allCases, id: \.self) { c in
                    Button(c.rawValue.capitalized) { store.mark(Set(flows.map(\.id))) { $0.color = c } }
                }
                Divider()
                Button("Strike Through") { store.mark(Set(flows.map(\.id))) { $0.strike.toggle() } }
                Button("Clear Highlight") { store.mark(Set(flows.map(\.id))) { $0.color = nil; $0.strike = false } }
            }
            Button("Comment…") {
                store.commentDraft = store.marks[f.id]?.comment ?? ""
                store.commenting = Set(flows.map(\.id))
            }
            Divider()
            Button("Export as HAR…") { store.exportHAR(http) }.disabled(http.isEmpty)
            Button("Save as Session…") { store.saveSession(flows) }
        }
    }
}

struct EmptyState: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 88, height: 88)
                .accessibilityHidden(true)
            Text("No traffic yet").font(.title2.weight(.semibold))
            Text("Point an app at Sekisho and every request it makes shows up here.")
                .foregroundStyle(.secondary)
            Button("Walk Me Through It…") { openWindow(id: "welcome") }
                .buttonStyle(.link)
                .foregroundStyle(Color.brass)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Send this Mac's traffic through Sekisho", done: store.systemProxyOn) {
                    Button("Turn On macOS Proxy") { store.setSystemProxy(true) }.disabled(!store.running)
                }
                step(2, "Trust Sekisho's certificate", done: store.caTrusted) {
                    Button("Trust Certificate…") { store.installCertificate() }
                }
                step(3, "Decrypt HTTPS: all of it, or host by host from a request", done: store.decryptsAll) {
                    Button("Decrypt All HTTPS") { store.decryptsAll = true }
                }
                step(4, "Or try it from a terminal", done: false) {
                    Text("curl -x http://127.0.0.1:\(String(store.port)) http://example.com")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func step(_ n: Int, _ text: String, done: Bool, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TabletPlate(number: n, mark: .brass, on: done)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).foregroundStyle(done ? .secondary : .primary)
                if !done { action() }
            }
        }
    }
}
