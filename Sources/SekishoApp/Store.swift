import AppKit
import Observation
import os
import SekishoCore
import SwiftUI
import UniformTypeIdentifiers

struct FlowMark: Codable, Hashable {
    var color: MarkColor?
    var strike = false
    var comment = ""
}

enum MarkColor: String, CaseIterable, Codable {
    case red, yellow, green, blue, purple, gray
    var color: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}

enum SidebarItem: Hashable {
    case all
    case app(String)
    case domain(String)
}

/// A request or response waiting at a breakpoint for the user's Execute or Abort.
struct PendingBreakpoint: Identifiable {
    let id = UUID()
    let stage: BreakpointStage
    let flow: Flow
    let resume: CheckedContinuation<Flow?, Never>
}

@MainActor @Observable
final class Store {
    static let shared = Store()

    private(set) var flows: [Flow] = []
    private var index: [Int: Int] = [:]
    /// The app behind each client connection, filled in by the proxy's lookup.
    private(set) var apps: [Int: ClientApp] = [:]
    /// Updates for flows at or below this id arrive after Clear and are dropped.
    private var clearedThrough = 0
    /// Removed one by one: later updates for them are dropped too.
    private var removedIDs: Set<Int> = []
    private var newestID = 0
    private(set) var inFlight = 0
    /// Content kind and GraphQL operation per flow, worked out once per update (they parse bodies).
    @ObservationIgnored private(set) var categories: [Int: Flow.Category] = [:]
    @ObservationIgnored private(set) var operations: [Int: String] = [:]

    var recording = true
    private(set) var running = false
    private(set) var startError: String?
    var port: Int = Demo.defaults.object(forKey: "port") as? Int ?? 9090 {
        didSet { Demo.defaults.set(port, forKey: "port"); restart() }
    }

    var rules: ProxyRules {
        didSet {
            // Typing in a rule changes it per keystroke: hand it to the proxy (and save it) once typing pauses.
            rulesApply?.cancel()
            rulesApply = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.applyRules()
            }
        }
    }
    @ObservationIgnored private var rulesApply: Task<Void, Never>?

    private func applyRules() {
        var effective = rules
        let user = effective.upstreamProxy?.username ?? ""
        effective.upstreamProxy?.password = Keychain.upstreamPassword(for: user) ?? ""
        proxy?.setRules(effective)
        if let data = try? JSONEncoder().encode(rules) { Demo.defaults.set(data, forKey: "rules") }
    }

    /// Serve other devices on the local network (phones, other Macs). Off by default.
    var allowLAN: Bool = Demo.defaults.bool(forKey: "allowLAN") {
        didSet { Demo.defaults.set(allowLAN, forKey: "allowLAN"); restart() }
    }

    var filterText = ""
    var sidebar: SidebarItem? = .all
    /// Filter chips: content categories plus "HTTP"/"HTTPS"; empty means everything.
    var chips: Set<String> = []
    /// Status classes (1...5); empty means every status.
    var statusChips: Set<Int> = []
    var onlyMarked = false
    /// Also search request and response bodies (slower; off by default).
    var searchBodies = false
    var sortOrder: [KeyPathComparator<Flow>] = [KeyPathComparator(\Flow.id)]
    /// Highlight colours, strike-through and comments, by flow id.
    var marks: [Int: FlowMark] = [:]
    /// Pinned hosts and app keys, kept across launches.
    var pinned: Set<String> = Set(Demo.defaults.stringArray(forKey: "pinned") ?? []) {
        didSet { Demo.defaults.set(Array(pinned), forKey: "pinned") }
    }
    var selection: Set<Int> = []
    /// A row to scroll into view: set by `reveal`, read by the list.
    var scrollTarget: Int?

    /// Selects one request and scrolls the list to it (the palette, Compose, the demo).
    func reveal(_ id: Int) {
        selection = [id]
        scrollTarget = id
    }

    private(set) var pending: [PendingBreakpoint] = []
    private(set) var systemProxyOn = false
    private(set) var caTrusted = false
    var notice: String?
    var composing: Flow?

    let ca: CertificateAuthority?
    private var proxy: ProxyServer?
    @ObservationIgnored private let inbox = OSAllocatedUnfairLock<(flows: [Flow], apps: [Int: ClientApp], scheduled: Bool)>(initialState: ([], [:], false))

    private init() {
        // An earlier version kept compose history (with credentials) in UserDefaults.
        Demo.defaults.removeObject(forKey: "composeHistory")
        if Demo.on {
            rules = Demo.rules
        } else if let data = Demo.defaults.data(forKey: "rules"), let saved = try? JSONDecoder().decode(ProxyRules.self, from: data) {
            rules = saved
        } else {
            rules = ProxyRules()
        }
        // The demo's certificate lives in memory only.
        do { ca = Demo.on ? try CertificateAuthority() : try CertificateAuthority(directory: Demo.support) } catch {
            ca = nil
            startError = "Sekisho's certificate authority could not be created: \(error.localizedDescription)"
        }
    }

    // MARK: Lifecycle

    func launch() {
        if Demo.on {
            running = true
            caTrusted = true
            return
        }
        // A snapshot left behind means Sekisho stopped without restoring the macOS proxy: put it back now.
        if let data = Demo.defaults.data(forKey: SystemProxy.snapshotKey),
           let snapshot = try? JSONDecoder().decode(SystemProxy.Snapshot.self, from: data) {
            SystemProxy.restore(snapshot)
            Demo.defaults.removeObject(forKey: SystemProxy.snapshotKey)
            notice = "Sekisho had quit without switching the macOS proxy back. It is back to how it was."
        }
        start()
        refreshTrust()
    }

    func start() {
        // The demo shows a listening proxy without opening a port.
        if Demo.on { running = true; return }
        guard let ca, proxy == nil else { return }
        do {
            var effective = rules
            let user = effective.upstreamProxy?.username ?? ""
            effective.upstreamProxy?.password = Keychain.upstreamPassword(for: user) ?? ""
            let server = try ProxyServer(port: port, ca: ca, rules: effective) { [weak self] flow in self?.receive(flow) }
            server.allowLAN = allowLAN
            server.onClientApp = { [weak self] connection, app in self?.receive(app, connection: connection) }
            server.scripts.log = { [weak self] line in
                Task { @MainActor in
                    guard let self else { return }
                    self.scriptLog.append("\(Formats.time.string(from: Date()))  \(line)")
                    if self.scriptLog.count > 500 { self.scriptLog.removeFirst(self.scriptLog.count - 500) }
                }
            }
            server.breakpointHandler = { [weak self] stage, flow in
                guard let self else { return flow }
                return await self.hold(stage, flow)
            }
            try server.start()
            proxy = server
            running = true
            startError = nil
        } catch {
            running = false
            startError = "Sekisho could not listen on 127.0.0.1:\(port): \(error.localizedDescription). Another app may be using that port; change it in Settings."
        }
    }

    func restart() {
        // Held requests belong to connections that are about to close.
        for p in pending { p.resume.resume(returning: nil) }
        pending.removeAll()
        let wasOn = systemProxyOn
        if wasOn { setSystemProxy(false) }
        proxy?.stop()
        proxy = nil
        running = false
        start()
        if wasOn && running { setSystemProxy(true) }
    }

    /// On quit: release held requests, put the macOS proxy back, close the listener.
    func shutdown() {
        rulesApply?.cancel()
        applyRules()
        for p in pending { p.resume.resume(returning: p.flow) }
        pending.removeAll()
        if systemProxyOn { setSystemProxy(false) }
        proxy?.stop()
    }

    // MARK: Incoming (from the proxy's threads)

    nonisolated private func receive(_ flow: Flow) {
        enqueue { $0.flows.append(flow) }
    }

    nonisolated private func receive(_ app: ClientApp, connection: Int) {
        enqueue { $0.apps[connection] = app }
    }

    /// Batches updates and applies them on the main actor at most ten times a second.
    nonisolated private func enqueue(_ change: (inout (flows: [Flow], apps: [Int: ClientApp], scheduled: Bool)) -> Void) {
        let schedule = inbox.withLock { box -> Bool in
            change(&box)
            defer { box.scheduled = true }
            return !box.scheduled
        }
        guard schedule else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.drain()
        }
    }

    private func drain() {
        let batch = inbox.withLock { box -> ([Flow], [Int: ClientApp]) in
            defer { box = ([], [:], false) }
            return (box.flows, box.apps)
        }
        apps.merge(batch.1) { $1 }
        for f in batch.0 {
            newestID = max(newestID, f.id)
            categories[f.id] = f.category
            operations[f.id] = f.graphQLOperation
            if let i = index[f.id] {
                flows[i] = f
            } else if f.id > clearedThrough && !removedIDs.contains(f.id) && (recording || f.interventions.contains(.replay)) {
                index[f.id] = flows.count
                flows.append(f)
            }
        }
        inFlight = flows.reduce(0) { $0 + ($1.kind == .http && $1.ended == nil && !$1.imported ? 1 : 0) }
    }

    // MARK: Views of the list

    var visibleFlows: [Flow] {
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let list = flows.filter { f in
            switch sidebar {
            case .app(let key)?: guard app(for: f)?.key == key else { return false }
            case .domain(let host)?: guard f.host == host else { return false }
            default: break
            }
            if !chips.isEmpty {
                let scheme = f.kind == .tunnel || f.scheme == "https" ? "HTTPS" : "HTTP"
                guard chips.contains((categories[f.id] ?? f.category).rawValue) || chips.contains(scheme) else { return false }
            }
            if !statusChips.isEmpty { guard let s = f.status, statusChips.contains(s / 100) else { return false } }
            if onlyMarked { guard let m = marks[f.id], m.color != nil || !m.comment.isEmpty else { return false } }
            guard !needle.isEmpty else { return true }
            if f.url.lowercased().contains(needle) || f.method.lowercased() == needle
                || f.status.map({ String($0).hasPrefix(needle) }) == true
                || marks[f.id]?.comment.lowercased().contains(needle) == true
                || operations[f.id]?.lowercased().contains(needle) == true { return true }
            guard searchBodies else { return false }
            // ponytail: a linear scan of the first MB of each body per keystroke; index if lists get huge.
            for body in [f.decodedRequestBody ?? f.requestBody, f.decodedResponseBody ?? f.responseBody] {
                if let text = String(data: body.prefix(1 << 20), encoding: .utf8), text.lowercased().contains(needle) { return true }
            }
            return false
        }
        return sortOrder == [KeyPathComparator(\Flow.id)] ? list : list.sorted(using: sortOrder)
    }

    /// The number shown for a flow: its id, or its place in the file it came from.
    func number(_ f: Flow) -> Int { f.id > 1_000_000 ? f.id - 1_000_000 : f.id }

    func app(for flow: Flow) -> ClientApp? { flow.connection.flatMap { apps[$0] } }

    func mark(_ ids: Set<Int>, _ change: (inout FlowMark) -> Void) {
        for id in ids { var m = marks[id] ?? FlowMark(); change(&m); marks[id] = m }
    }

    /// Script console output, newest last, the last 500 lines.
    var scriptLog: [String] = []
    /// Why a reverse proxy is not listening, by rule id.
    var reverseErrors: [UUID: String] { _ = rules; return proxy?.reverseErrors ?? [:] }

    /// Screenshot states (ScreenshotDirector): tabs and body mode the panes open on.
    var shotRequestTab: String?
    var shotResponseTab: String?
    var shotBodyMode: String?
    var shotSidebarHidden = false
    var shotWelcomeStation: Int?
    var shotMaximise: String?

    /// Holds a recorded flow at a pretend breakpoint, for screenshots of the Breakpoint window.
    func holdForShot(_ flow: Flow) async -> Flow? { await hold(.request, flow) }

    /// A tool the palette asked the Tools window to show.
    var requestedTool: Tool?

    /// The first request picked for Compare.
    var compareBase: Int?

    var commenting: Set<Int>?
    var commentDraft = ""

    /// Pinned hosts and apps that have traffic, for the sidebar's Pinned section.
    var pinnedRows: [(key: String, title: String, count: Int, item: SidebarItem)] {
        var rows: [(key: String, title: String, count: Int, item: SidebarItem)] = []
        for g in appGroups where pinned.contains(g.app.key) { rows.append((g.app.key, g.app.name, g.count, .app(g.app.key))) }
        for g in domainGroups where pinned.contains(g.host) { rows.append((g.host, g.host, g.count, .domain(g.host))) }
        return rows
    }

    func togglePin(_ key: String) { if pinned.contains(key) { pinned.remove(key) } else { pinned.insert(key) } }

    var appGroups: [(app: ClientApp, count: Int)] {
        var counts: [String: (ClientApp, Int)] = [:]
        for f in flows { if let a = app(for: f) { counts[a.key, default: (a, 0)].1 += 1 } }
        return counts.values.map { (app: $0.0, count: $0.1) }.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    var domainGroups: [(host: String, count: Int)] {
        var counts: [String: Int] = [:]
        for f in flows { counts[f.host, default: 0] += 1 }
        return counts.map { (host: $0.key, count: $0.value) }.sorted { $0.host < $1.host }
    }

    var selectedFlows: [Flow] { selection.compactMap { index[$0].map { flows[$0] } }.sorted { $0.id < $1.id } }
    var selectedFlow: Flow? { selection.count == 1 ? selectedFlows.first : nil }
    func flow(_ id: Int) -> Flow? { index[id].map { flows[$0] } }

    func clear() {
        clearedThrough = newestID
        marks.removeAll()
        flows.removeAll()
        index.removeAll()
        selection.removeAll()
        inFlight = 0
    }

    // MARK: Breakpoints

    private func hold(_ stage: BreakpointStage, _ flow: Flow) async -> Flow? {
        NSApp.requestUserAttention(.informationalRequest)
        return await withCheckedContinuation { continuation in
            pending.append(PendingBreakpoint(stage: stage, flow: flow, resume: continuation))
        }
    }

    func releaseAll() {
        for p in pending { p.resume.resume(returning: p.flow) }
        pending.removeAll()
    }

    func resolve(_ id: UUID, with flow: Flow?) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: i).resume.resume(returning: flow)
    }

    // MARK: Actions

    func repeatRequests(_ list: [Flow]) {
        for f in list where f.kind == .http { proxy?.replay(f) }
    }

    /// Sends a composed or edited request and selects it in the list. Returns its id.
    @discardableResult
    func send(_ request: Flow) -> Int? {
        remember(composed: request)
        guard let id = proxy?.replay(request) else { return nil }
        reveal(id)
        return id
    }

    /// Puts a host pattern on the SSL Proxying list (the proxy closes open tunnels to it).
    func enableSSL(_ pattern: String) {
        let p = pattern.lowercased()
        if !rules.sslProxying.contains(p) { rules.sslProxying.append(p) }
        rulesApply?.cancel()
        applyRules()
    }

    var decryptsAll: Bool {
        get { rules.sslProxying.contains("*") }
        set { if newValue { enableSSL("*") } else { rules.sslProxying.removeAll { $0 == "*" } } }
    }

    func remove(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        flows.removeAll { ids.contains($0.id) }
        index = Dictionary(uniqueKeysWithValues: flows.enumerated().map { ($1.id, $0) })
        selection.subtract(ids)
        removedIDs.formUnion(ids)
    }

    func copyCurl(_ list: [Flow]) {
        copy(list.filter { $0.kind == .http }.map(Export.curl).joined(separator: "\n\n"))
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Sessions, imports, compose history

    private var importedCount = 0
    private var importedConnections = 0

    /// Puts flows from a file into the list, renumbered past anything live (they never collide with the proxy's ids).
    private func add(imported list: [Flow], marks: [Int: FlowMark] = [:], apps sessionApps: [Int: ClientApp] = [:]) {
        // Connection ids from the file get fresh numbers past the live ones, keeping their apps.
        var connections: [Int: Int] = [:]
        for var f in list {
            importedCount += 1
            let old = f.id
            f.id = 1_000_000 + importedCount
            f.imported = true
            if let c = f.connection {
                let fresh = connections[c] ?? { importedConnections += 1; return 1_000_000 + importedConnections }()
                connections[c] = fresh
                f.connection = fresh
                if let app = sessionApps[c] { apps[fresh] = app }
            }
            index[f.id] = flows.count
            flows.append(f)
            categories[f.id] = f.category
            operations[f.id] = f.graphQLOperation
            if let m = marks[old] { self.marks[f.id] = m }
        }
    }

    func saveSession(_ list: [Flow]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sekisho session.sekisho"
        panel.allowedContentTypes = [UTType(filenameExtension: "sekisho") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let ids = Set(list.map(\.id))
            let marks = try JSONEncoder().encode(self.marks.filter { ids.contains($0.key) })
            let connections = Set(list.compactMap(\.connection))
            try SessionFile(flows: list, marks: marks, apps: apps.filter { connections.contains($0.key) }).encoded().write(to: url)
        } catch {
            notice = "The session could not be saved: \(error.localizedDescription)"
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sekisho") ?? .json, UTType(filenameExtension: "har") ?? .json, .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    /// A saved session or a HAR file, recognised by content.
    func open(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            if let session = try? SessionFile.decode(data) {
                let marks = session.marks.flatMap { try? JSONDecoder().decode([Int: FlowMark].self, from: $0) } ?? [:]
                add(imported: session.flows, marks: marks, apps: session.apps ?? [:])
            } else {
                let flows = try Import.har(data)
                guard !flows.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                add(imported: flows)
            }
        } catch {
            notice = "\(url.lastPathComponent) is not a Sekisho session or a HAR file (\(error.localizedDescription))."
        }
    }

    /// The last requests sent from Compose, newest first, in Application Support (not UserDefaults).
    var composeHistory: [Flow] = Store.loadHistory()

    private static var historyURL: URL {
        Demo.support.appendingPathComponent("compose-history.json")
    }
    private static func loadHistory() -> [Flow] {
        (try? Data(contentsOf: historyURL)).flatMap { try? JSONDecoder().decode([Flow].self, from: $0) } ?? []
    }

    func remember(composed f: Flow) {
        var f = f
        f.id = 0
        f.responseBody = Data(); f.responseHeaders = []; f.status = nil; f.messages = []
        // Credentials are not kept: history is a convenience, not a vault.
        f.requestHeaders.removeAll { ["authorization", "cookie", "proxy-authorization", "x-api-key"].contains($0.name.lowercased()) }
        // ponytail: bodies over 256 KB are not kept in history.
        if f.requestBody.count > 256 << 10 { f.requestBody = Data() }
        var list = composeHistory
        list.removeAll { $0.method == f.method && $0.url == f.url && $0.requestBody == f.requestBody }
        list.insert(f, at: 0)
        composeHistory = Array(list.prefix(30))
        let data = try? JSONEncoder().encode(composeHistory)
        let url = Self.historyURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data?.write(to: url, options: [.atomic])
        }
    }

    func copyCode(_ f: Flow, _ language: CodeLanguage) { copy(CodeGen.generate(f, language)) }

    func exportHAR(_ list: [Flow]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sekisho \(Formats.time.string(from: Date()).prefix(8).replacingOccurrences(of: ":", with: ".")).har"
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            try Export.har(list, version: version).write(to: url)
        } catch {
            notice = "The HAR file could not be written: \(error.localizedDescription)"
        }
    }

    func toggleSSLProxying(_ host: String) {
        if let i = rules.sslProxying.firstIndex(of: host) { rules.sslProxying.remove(at: i) } else { rules.sslProxying.append(host) }
    }

    func toggleBlock(_ host: String) {
        if let i = rules.blocked.firstIndex(of: host) { rules.blocked.remove(at: i) } else { rules.blocked.append(host) }
    }

    /// A breakpoint on this exact URL (without its query), for requests and responses.
    func addBreakpoint(_ f: Flow) {
        let base = f.url.split(separator: "?").first.map(String.init) ?? f.url
        rules.breakpoints.append(BreakpointRule(pattern: base + "*", method: f.method, request: true, response: true))
    }

    /// Map Local seeded with the response Sekisho saw, so it can be edited from there.
    func addMapLocal(_ f: Flow) {
        let base = f.url.split(separator: "?").first.map(String.init) ?? f.url
        let body = String(data: f.decodedResponseBody ?? Data(), encoding: .utf8) ?? ""
        rules.mapLocal.append(MapLocalRule(pattern: base + "*", status: f.status ?? 200,
                                           contentType: f.responseHeader("Content-Type") ?? "application/json", body: body))
    }

    func addMapRemote(_ f: Flow) {
        rules.mapRemote.append(MapRemoteRule(pattern: "\(f.scheme)://\(f.authority)/*", destination: "http://localhost:3000"))
    }

    // MARK: macOS proxy and certificate

    func setSystemProxy(_ on: Bool) {
        // The demo only pretends: this Mac's network settings stay as they are.
        if Demo.on { systemProxyOn = on && running; return }
        if on {
            guard running else { return }
            // The snapshot is saved before anything changes, so a crash halfway is still undone at next launch.
            let before = SystemProxy.current()
            do {
                Demo.defaults.set(try JSONEncoder().encode(before), forKey: SystemProxy.snapshotKey)
                let refused = try SystemProxy.enable(port: port, before: before)
                systemProxyOn = true
                if !refused.isEmpty { notice = "The macOS proxy is on, except for \(refused.joined(separator: ", ")), which refused the setting." }
            } catch {
                Demo.defaults.removeObject(forKey: SystemProxy.snapshotKey)
                notice = "The macOS proxy could not be switched on: \(error.localizedDescription)"
            }
        } else {
            if let data = Demo.defaults.data(forKey: SystemProxy.snapshotKey),
               let before = try? JSONDecoder().decode(SystemProxy.Snapshot.self, from: data) {
                SystemProxy.restore(before)
            }
            Demo.defaults.removeObject(forKey: SystemProxy.snapshotKey)
            systemProxyOn = false
        }
    }

    func refreshTrust() {
        guard let ca, !Demo.on else { return }
        caTrusted = CertificateTrust.isTrusted(ca)
    }

    func installCertificate() {
        guard let ca, !Demo.on else { notice = Demo.on ? "This is the demo: the certificate is not installed." : nil; return }
        Task.detached {
            let result = Result { try CertificateTrust.install(ca) }
            await MainActor.run {
                if case .failure(let error) = result { self.notice = "The certificate was not trusted: \(error.localizedDescription)" }
                self.refreshTrust()
            }
        }
    }

    func removeCertificate() {
        guard let ca, !Demo.on else { notice = Demo.on ? "This is the demo: there is no certificate to remove." : nil; return }
        Task.detached {
            let result = Result { try CertificateTrust.remove(ca) }
            await MainActor.run {
                switch result {
                case .failure(let error): self.notice = "The certificate could not be removed: \(error.localizedDescription)"
                case .success: self.notice = "Sekisho's certificate is no longer trusted and its key is deleted. A new one is made the next time Sekisho starts."
                }
                self.refreshTrust()
            }
        }
    }

    /// Adds Sekisho's CA to every booted iOS Simulator (`simctl keychain add-root-cert`).
    func installInSimulators() {
        guard let ca, !Demo.on else { notice = Demo.on ? "This is the demo: nothing is installed in the Simulators." : nil; return }
        let pem = FileManager.default.temporaryDirectory.appendingPathComponent("Sekisho CA.pem")
        Task.detached {
            var message: String
            do {
                try ca.rootPEM.write(to: pem, atomically: true, encoding: .utf8)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = ["simctl", "keychain", "booted", "add-root-cert", pem.path]
                let err = Pipe()
                p.standardError = err
                p.standardOutput = FileHandle.nullDevice
                try p.run()
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                message = p.terminationStatus == 0
                    ? "Sekisho's certificate is installed in the booted iOS Simulators. Restart the app in the simulator."
                    : "No booted simulator took the certificate: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            } catch {
                message = "The simulator certificate could not be installed: \(error.localizedDescription)"
            }
            try? FileManager.default.removeItem(at: pem)
            let text = message
            await MainActor.run { self.notice = text }
        }
    }

    func exportCertificate() {
        guard let ca else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sekisho CA.pem"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ca.rootPEM.write(to: url, atomically: true, encoding: .utf8) } catch {
            notice = "The certificate could not be saved: \(error.localizedDescription)"
        }
    }
}
