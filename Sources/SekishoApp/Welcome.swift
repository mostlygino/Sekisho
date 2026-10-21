import AppKit
import SekishoCore
import SwiftUI

/// First launch: five stations on a single-track line, from "what is this" to the first decrypted request. Every
/// station does the real thing (trust the certificate, switch the proxy, pick hosts) and checks it live, so the walk
/// ends on the moment that proves Sekisho works: your own HTTPS request, readable. Skippable at every station;
/// shown once, and again from Help > Welcome to Sekisho.
struct WelcomeWindow: View {
    enum Station: Int, CaseIterable, Identifiable {
        case welcome, certificate, route, decrypt, ready
        var id: Int { rawValue }
        var name: String {
            switch self {
            case .welcome: "Welcome"
            case .certificate: "Certificate"
            case .route: "Traffic"
            case .decrypt: "Decrypt"
            case .ready: "Line clear"
            }
        }
        var detail: String {
            switch self {
            case .welcome: "What Sekisho does"
            case .certificate: "Read HTTPS"
            case .route: "Send requests through"
            case .decrypt: "Pick the hosts"
            case .ready: "Where to go next"
            }
        }
    }

    @Environment(Store.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var station: Station = .welcome
    @State private var forward = true
    /// Requests newer than this arrived while the walk was open.
    @State private var baseline = Int.max

    var body: some View {
        HStack(spacing: 0) {
            Rail(station: station, done: done, go: go)
                .frame(width: 222)
                .background(Color.ground.ignoresSafeArea())
            Rectangle().fill(Color.rule).frame(width: 1)
            VStack(spacing: 0) {
                page
                    .id(station)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(x: forward ? 24 : -24).combined(with: .opacity),
                        removal: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 36)
                    .padding(.top, 40)
                footer
            }
            .background(Color.raised.ignoresSafeArea())
        }
        .frame(width: 820, height: 560)
        .onChange(of: store.shotWelcomeStation) { _, s in if let s = s.flatMap(Station.init(rawValue:)) { station = s } }
        .onAppear {
            baseline = store.flows.filter { !$0.imported }.map(\.id).max() ?? 0
            if let s = store.shotWelcomeStation.flatMap(Station.init(rawValue:)) { station = s }
            store.refreshTrust()
        }
        .onDisappear { Demo.defaults.set(true, forKey: WelcomeWindow.seenKey) }
    }

    static let seenKey = "welcomeSeen"

    // MARK: Progress

    /// Live: what is already true on this Mac, whatever station the walk is at.
    private var done: Set<Station> {
        var s: Set<Station> = [.welcome]
        if store.caTrusted { s.insert(.certificate) }
        if !fresh.isEmpty { s.insert(.route) }
        if firstDecrypted != nil { s.insert(.decrypt) }
        return s
    }

    /// The demo's recorded session counts as live traffic, so its walk shows each station done.
    private var fresh: [Flow] { Demo.on ? store.flows : store.flows.filter { !$0.imported && $0.id > baseline } }
    private var firstDecrypted: Flow? { fresh.first { $0.kind == .http && $0.scheme == "https" && $0.status != nil } }

    private func go(_ next: Station) {
        forward = next.rawValue > station.rawValue
        withAnimation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.55)) { station = next }
    }

    private func finish() {
        Demo.defaults.set(true, forKey: WelcomeWindow.seenKey)
        if let f = firstDecrypted { store.reveal(f.id) }
        dismissWindow(id: "welcome")
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch station {
        case .welcome: WelcomePage(explore: {
            if let url = Demo.session { store.open(url) }
            finish()
        })
        case .certificate: CertificatePage()
        case .route: RoutePage(fresh: fresh)
        case .decrypt: DecryptPage(first: firstDecrypted, back: { go(.certificate) })
        case .ready: ReadyPage(openTools: { openWindow(id: "tools") })
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.rule).frame(height: 1)
            HStack(spacing: 10) {
                if station != .ready {
                    Button("Skip Setup") { finish() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                        .help("Close this; Help > Welcome to Sekisho brings it back")
                }
                Spacer()
                Text("\(station.rawValue + 1) of \(Station.allCases.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 6)
                if let previous = Station(rawValue: station.rawValue - 1) {
                    Button("Back") { go(previous) }
                }
                Button(primaryTitle) {
                    if let next = Station(rawValue: station.rawValue + 1) { go(next) } else { finish() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.brassFill)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    private var primaryTitle: String {
        switch station {
        case .welcome: "Get Started"
        case .certificate: store.caTrusted ? "Continue" : "Continue Without"
        case .route, .decrypt: "Continue"
        case .ready: "Start Using Sekisho"
        }
    }
}

// MARK: The line

/// The walk as a single-track line: stations passed are lit, the tablet rides to the one you are at.
private struct Rail: View {
    let station: WelcomeWindow.Station
    let done: Set<WelcomeWindow.Station>
    let go: (WelcomeWindow.Station) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let top: CGFloat = 132, gap: CGFloat = 66, track: CGFloat = 34

    var body: some View {
        ZStack(alignment: .topLeading) {
            header.padding(.leading, 22).padding(.top, 46)
            Sleepers(x: track, from: top, to: top + gap * 4)
            ForEach(WelcomeWindow.Station.allCases) { s in
                Button { go(s) } label: { stop(s) }
                    .buttonStyle(.plain)
                    .offset(x: track - 9, y: top + gap * CGFloat(s.rawValue) - 9)
                    .accessibilityLabel("\(s.name), \(done.contains(s) ? "done" : "not done")")
                    .accessibilityAddTraits(s == station ? .isSelected : [])
            }
            TabletToken()
                .frame(width: 26, height: 26)
                .offset(x: track - 13, y: top + gap * CGFloat(station.rawValue) - 13)
                .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.55), value: station)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 38, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Getting started").font(.headline)
                Text("About a minute").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stop(_ s: WelcomeWindow.Station) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.raised)
                Circle().strokeBorder(done.contains(s) ? Color.brass : Color.rule, lineWidth: 2)
                if done.contains(s) && s != station {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Color.brass)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name)
                    .font(.system(size: 13, weight: s == station ? .semibold : .regular))
                    .foregroundStyle(s == station ? .primary : .secondary)
                Text(s.detail).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.leading, 8)
        }
        .contentShape(Rectangle())
    }
}

/// Two rails and their sleepers, drawn down the side of the window.
private struct Sleepers: View {
    let x: CGFloat, from: CGFloat, to: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            var y = from + 4
            while y < to - 4 {
                ctx.fill(Path(CGRect(x: x - 9, y: y, width: 18, height: 2.6)), with: .color(Color.rule))
                y += 9
            }
            for railX in [x - 4.5, x + 4.5] {
                var rail = Path()
                rail.move(to: CGPoint(x: railX, y: from)); rail.addLine(to: CGPoint(x: railX, y: to))
                ctx.stroke(rail, with: .color(Color.brass.opacity(0.55)), lineWidth: 1.4)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The tablet itself, as on the record control.
private struct TabletToken: View {
    var body: some View {
        TabletMark().shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }
}

// MARK: Station pages

private struct PageTitle: View {
    let kicker: String, title: String, lede: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kicker.uppercased()).font(.caption.weight(.semibold)).kerning(1.2).foregroundStyle(Color.brass)
            Text(title).font(.system(size: 26, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(lede).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 500, alignment: .leading)
        }
    }
}

/// A quiet panel on the page: ground-coloured, hairline edge.
private struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.rule, lineWidth: 1))
    }
}

private struct WelcomePage: View {
    let explore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageTitle(kicker: "Sekisho 関所", title: "Stop, read and change every request on its way through.",
                      lede: "Sekisho sits between the apps on this Mac and the servers they talk to. Three stops and you will see your own HTTPS traffic, readable.")
            VStack(alignment: .leading, spacing: 14) {
                feature("eye", "See", "Every request, with the app that sent it, its headers, body and timing.")
                feature("lock.open", "Open HTTPS", "Decrypt only the hosts you pick, with a certificate made on this Mac.")
                feature(Intervention.hold.symbol, "Change", "Hold a request at a breakpoint, answer it from a file, or rewrite it with a script.")
            }
            Panel {
                Label {
                    Text("Everything stays on this Mac. Sekisho listens on 127.0.0.1 only, its certificate's key never leaves, and the macOS proxy goes back to how it was when you quit.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised").foregroundStyle(Color.brass)
                }
                .font(.callout)
            }
            Button(action: explore) { Label("Look Around a Recorded Session First", systemImage: "play.rectangle") }
                .buttonStyle(.link)
                .foregroundStyle(Color.brass)
                .help("Opens a demo session with example traffic, without changing anything on this Mac")
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.brass).frame(width: 20)
            Text(title).fontWeight(.semibold).frame(width: 96, alignment: .leading)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CertificatePage: View {
    @Environment(Store.self) private var store
    @State private var asked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageTitle(kicker: "Station 2", title: "Let Sekisho read HTTPS",
                      lede: "HTTPS is sealed between an app and its server. To open it, Sekisho answers for the server with a certificate it signs itself, and your Mac accepts those only if it trusts Sekisho's own certificate authority.")
            Panel {
                HStack(spacing: 14) {
                    Image(systemName: store.caTrusted ? "checkmark.seal.fill" : "seal")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(store.caTrusted ? Color.statusOK : Color.brass)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.caTrusted ? "Trusted on this Mac" : "Sekisho CA, made on this Mac").font(.headline)
                        Text(store.caTrusted ? "Apps will accept Sekisho's certificates for the hosts you decrypt."
                             : asked ? "Waiting for macOS. Enter your password in its dialog." : "Not trusted yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !store.caTrusted {
                        Button("Trust Certificate…") { asked = true; store.installCertificate() }
                            .buttonStyle(.borderedProminent).tint(.brassFill)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                note("lock.shield", "macOS asks for your password. The trust covers websites only (SSL), nothing else.")
                note("key", "The private key stays in Application Support, readable by you alone. It never leaves this Mac.")
                note("arrow.uturn.backward", "Settings > Certificate removes the trust and deletes the key again.")
            }
            if !store.caTrusted {
                Text("You can do this later. Until then HTTP is readable and HTTPS passes through, still encrypted.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

private func note(_ symbol: String, _ text: String) -> some View {
    Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
        .font(.callout)
        .foregroundStyle(.secondary)
}

private struct RoutePage: View {
    @Environment(Store.self) private var store
    let fresh: [Flow]
    @State private var copied: String?

    private var hostPort: String { "127.0.0.1:\(String(store.port))" }
    private var address: String { "http://" + hostPort }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(kicker: "Station 3", title: "Send traffic through Sekisho",
                      lede: "Sekisho sees what is sent to it. Point the whole Mac at it, or just one app or terminal.")
            HStack(alignment: .top, spacing: 14) {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("This whole Mac", systemImage: "desktopcomputer").font(.headline)
                        Text("Browsers and most apps follow the macOS proxy. The old settings come back when you switch it off or quit.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Toggle("macOS Proxy", isOn: Binding(get: { store.systemProxyOn }, set: { store.setSystemProxy($0) }))
                            .toggleStyle(.switch)
                            .disabled(!store.running)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("One app or a terminal", systemImage: "terminal").font(.headline)
                        command("curl -x \(hostPort) https://example.com")
                        command("export HTTPS_PROXY=\(address)")
                        Text("Or set \(hostPort) as the HTTP and HTTPS proxy in an app's own settings.")
                            .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            LiveSignal(fresh: fresh)
        }
    }

    private func command(_ text: String) -> some View {
        HStack(spacing: 6) {
            // Wrapped, never cut: a command with an ellipsis in it is no use to copy by eye.
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { store.copy(text); copied = text } label: {
                Image(systemName: copied == text ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel(copied == text ? "Copied" : "Copy command")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// "Waiting for the first request", then who is talking: proof that traffic arrives.
private struct LiveSignal: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fresh: [Flow]
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(fresh.isEmpty ? Color.brass : Color.statusOK)
                .frame(width: 8, height: 8)
                .opacity(fresh.isEmpty && pulse ? 0.25 : 1)
                .animation(fresh.isEmpty && !reduceMotion ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: pulse)
                .onAppear { pulse = true }
            Text(summary).font(.callout).foregroundStyle(fresh.isEmpty ? .secondary : .primary)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        guard !fresh.isEmpty else { return "Waiting for the first request…" }
        let apps = Array(Set(fresh.compactMap { store.app(for: $0)?.name })).sorted().prefix(3)
        let n = fresh.count == 1 ? "1 request" : "\(fresh.count) requests"
        return apps.isEmpty ? "\(n) so far." : "\(n) so far, from \(apps.joined(separator: ", "))."
    }
}

private struct DecryptPage: View {
    @Environment(Store.self) private var store
    let first: Flow?
    let back: () -> Void
    @State private var draft = ""

    /// The busiest hosts that use HTTPS (tunnels or decrypted), up to a dozen.
    private var hosts: [String] {
        var counts: [String: Int] = [:]
        for f in store.flows where (Demo.on || !f.imported) && (f.kind == .tunnel || f.scheme == "https") { counts[f.host, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(12).map(\.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(kicker: "Station 4", title: "Choose what to decrypt",
                      lede: "Only the hosts you pick are opened; everything else passes through untouched, as an encrypted tunnel. Pick from what Sekisho has seen, or decrypt it all.")
            if hosts.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hosts appear here as HTTPS traffic comes in. Or add one:").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            TextField("api.example.com", text: $draft).textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced)).onSubmit(add)
                            Button("Decrypt", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            } else {
                FlowingChips(hosts: hosts)
            }
            Toggle("Decrypt all HTTPS", isOn: Binding(get: { store.decryptsAll }, set: { store.decryptsAll = $0 }))
                .toggleStyle(.switch)
                .help("Every host, not only the ones you pick. Apps that pin their certificates will refuse to connect.")
            if let first {
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Your first decrypted request", systemImage: "lock.open.fill").font(.headline).foregroundStyle(Color.statusOK)
                        HStack(spacing: 8) {
                            StatusDot(first)
                            Text(String(first.status ?? 0)).font(.system(.callout, design: .monospaced))
                            Text(first.method).font(.system(.callout, design: .monospaced).weight(.semibold))
                            Text(first.host + first.path).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let app = store.app(for: first) {
                                Image(nsImage: AppIcons.icon(for: app)).resizable().frame(width: 16, height: 16)
                                Text(app.name).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Text("Headers, body and timings are all readable now. It is selected in the list when you finish.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            } else if !store.caTrusted {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusClient)
                    Text("Apps refuse decrypted connections until the certificate is trusted.").font(.callout)
                    Button("Trust It", action: back).buttonStyle(.link)
                }
            } else {
                Text("Reload a page or rerun a request to one of these hosts to see it decrypted.").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    private func add() {
        let host = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return }
        store.enableSSL(host)
        draft = ""
    }
}

/// Host chips that wrap onto as many lines as they need; on means decrypted.
private struct FlowingChips: View {
    @Environment(Store.self) private var store
    let hosts: [String]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(hosts, id: \.self) { host in
                let on = store.rules.intercepts(host)
                Button {
                    if store.rules.sslProxying.contains(host) { store.toggleSSLProxying(host) } else if !on { store.enableSSL(host) }
                } label: {
                    Label(host, systemImage: on ? "lock.open.fill" : "lock.fill")
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(Capsule().fill(on ? Color.brassFill : Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(on ? (store.rules.sslProxying.contains(host) ? "Decrypted. Click to stop." : "Decrypted by a wider rule") : "Click to decrypt \(host)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Lays children out left to right, wrapping at the proposed width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in rows(subviews, width: bounds.width).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + line))
    }
}

private struct ReadyPage: View {
    let openTools: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(kicker: "Line clear", title: "You hold the tablet.",
                      lede: "Traffic is yours to read. A few places worth knowing on the way:")
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    tip("command", "Find anything", "Requests, hosts, apps and every action.", keys: "⌘K")
                    tip(Intervention.hold.symbol, "Stop and edit", "A breakpoint holds a request or response so you can change it.", keys: "⇧⌘T")
                }
                GridRow {
                    tip(Intervention.mapLocal.symbol, "Answer from a file", "Map Local replies for the server, from text, a file or a folder.", keys: "⇧⌘T")
                    tip("arrow.clockwise", "Repeat and compose", "Send a request again, edited, or build one from cURL.", keys: "⌘R  ⌘N")
                }
            }
            HStack(spacing: 16) {
                Button("Open Tools", action: openTools).buttonStyle(.link).foregroundStyle(Color.brass)
                Text("This walk comes back from Help > Welcome to Sekisho.").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    private func tip(_ symbol: String, _ title: String, _ text: String, keys: String) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(Color.brass)
                    Text(title).fontWeight(.semibold)
                    Spacer()
                    Text(keys).font(.system(.caption, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.rule, lineWidth: 1))
                }
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
