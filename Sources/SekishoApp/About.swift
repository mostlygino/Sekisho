import AppKit
import SekishoCore
import SwiftUI

/// About Sekisho, laid out as an okuzuke (奥付), the colophon at the back of a Japanese book, like Kekkai's and
/// Shīru's: the edition (版), the printing (刷), the author's seal pressed on a paper slip (検印), and one line
/// for how the checkpoint (関) stands on this Mac right now.
struct AboutView: View {
    static let developer = "Gino de Graaff"
    static let handle = "mostlygino"
    static let website = URL(string: "https://mostlygino.com")!
    static let repository = URL(string: "https://github.com/mostlygino/Sekisho")!
    /// Seal paste: the one red that is not a status. Shared with Kekkai and Shīru's seals.
    static let seal = Color(red: 0.85, green: 0.255, blue: 0.17)

    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    @State private var bloom = false
    @State private var copied = false

    private let build = BuildInfo.current

    var body: some View {
        VStack(spacing: 0) {
            hero
                .padding(.top, 40)
                .padding(.horizontal, 32)
            colophon
                .padding(.top, 26)
                .padding(.horizontal, 26)
            actions
                .padding(.top, 18)
            footer
                .padding(.top, 22)
                .padding(.bottom, 24)
                .padding(.horizontal, 32)
        }
        .frame(width: 480)
        .background { LinenGround().ignoresSafeArea() }
        .task { await stamp() }
    }

    // MARK: Title

    private var hero: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Sekisho")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                Text("関所")
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(Color.brass)
                    .accessibilityHidden(true)
            }
            Text("A checkpoint for your Mac's traffic. Read every request, decrypt the hosts you choose, and change them on the way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
    }

    // MARK: Colophon

    private var colophon: some View {
        HStack(alignment: .center, spacing: 20) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                entry(mark: "版", label: "Version") {
                    HStack(spacing: 6) {
                        Text(build.version).font(.body.weight(.semibold)).monospacedDigit()
                        channelTag
                    }
                }
                entry(mark: "刷", label: "Build") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(build.number).font(.system(.callout, design: .monospaced))
                            copyButton
                        }
                        buildDetail
                    }
                }
                entry(mark: "関", label: "Checkpoint") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            TabletMark(on: store.running)
                                .frame(width: 12, height: 12)
                            Text(store.running ? "Open" : "Closed").font(.body.weight(.semibold))
                        }
                        Text(checkpointDetail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                entry(mark: "著", label: "Built by") {
                    VStack(alignment: .leading, spacing: 2) {
                        Link(Self.handle, destination: Self.website)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.brass)
                            .help("mostlygino.com")
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Self.seal)
                                .symbolEffect(.bounce, value: bloom)
                            Text("Built with love by \(Self.developer)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            kenin
        }
        .padding(.vertical, 18)
        .padding(.leading, 18)
        .padding(.trailing, 20)
        .background(Color.brass.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.brass.opacity(0.25), lineWidth: 1))
    }

    private var checkpointDetail: String {
        guard store.running else { return store.startError ?? "Not listening" }
        let decrypting = store.decryptsAll ? "decrypting all HTTPS" : "decrypting \(store.rules.sslProxying.count) \(store.rules.sslProxying.count == 1 ? "host" : "hosts")"
        let where_ = store.allowLAN ? "this Mac and the network" : "127.0.0.1"
        return "\(where_):\(String(store.port)) · \(store.flows.count) recorded · \(decrypting)"
    }

    private func entry(mark: String, label: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(mark)
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(Color.brass)
                .accessibilityHidden(true)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            value()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var channelTag: some View {
        switch build.channel {
        case .beta: ChannelTag(text: "Beta", tint: Color.brass)
        case .development: ChannelTag(text: "Development build", tint: .secondary)
        case .release: EmptyView()
        }
    }

    /// "19 October 2026 · ffadd4e", the commit linking to its page on GitHub.
    @ViewBuilder
    private var buildDetail: some View {
        HStack(spacing: 5) {
            if let date = build.date {
                Text(date, format: .dateTime.day().month(.wide).year())
            }
            if build.date != nil, build.commit != nil { Text("·").accessibilityHidden(true) }
            if let commit = build.commit {
                Link(commit, destination: Self.repository.appendingPathComponent("commit/\(commit.trimmingCharacters(in: CharacterSet(charactersIn: "+")))"))
                    .font(.system(.caption, design: .monospaced))
                    .help(commit.hasSuffix("+") ? "Built with uncommitted changes on top of this commit" : "Show this commit on GitHub")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: The seal

    /// The 検印 slip: a scrap of paper the author stamps by hand, with the mostlygino.com icon. Click it to stamp again.
    private var kenin: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(red: 0.97, green: 0.955, blue: 0.93))
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .strokeBorder(Self.seal.opacity(0.35), lineWidth: 0.75)
                    .padding(5)
                Ellipse()
                    .stroke(Self.seal, lineWidth: 2)
                    .frame(width: 64, height: 52)
                    .scaleEffect(bloom ? 1.45 : 1)
                    .opacity(pressed && !bloom ? 0.5 : 0)
                if let developer = Self.developerImage {
                    Image(nsImage: developer)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 62, height: 62)
                        .rotationEffect(.degrees(-6))
                        .shadow(color: .black.opacity(pressed ? 0.25 : 0), radius: pressed ? 2 : 8, y: pressed ? 1 : 6)
                        .scaleEffect(pressed ? 1 : 1.6)
                        .opacity(pressed ? 1 : 0)
                        .blur(radius: pressed ? 0 : 5)
                }
            }
            .frame(width: 82, height: 82)
            .rotationEffect(.degrees(1.5))
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1.5)
            .contentShape(Rectangle())
            .onTapGesture { Task { await stamp() } }
            Text("検印")
                .font(.system(size: 10, weight: .medium, design: .serif))
                .tracking(3)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.handle) seal")
    }

    static let developerImage: NSImage? = Bundle.main.url(forResource: "mostlygino", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    /// The one authored moment: the seal drops, lands with a tap you can feel on the trackpad, and the ink spreads.
    private func stamp() async {
        guard !reduceMotion else { pressed = true; return }
        pressed = false
        bloom = false
        try? await Task.sleep(for: .milliseconds(320))
        withAnimation(.easeIn(duration: 0.2)) { pressed = true }
        try? await Task.sleep(for: .milliseconds(200))
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(.easeOut(duration: 0.7)) { bloom = true }
    }

    // MARK: Actions

    /// Copies version, build, commit, proxy state and macOS as plain text for a bug report.
    private var copyButton: some View {
        Button {
            Store.shared.copy(build.report(checkpoint: checkpointDetail))
            withAnimation(.snappy) { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(.snappy) { copied = false } }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Color.brass : .secondary)
        .help("Copy version info for a bug report")
        .accessibilityLabel(copied ? "Copied" : "Copy version info")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Release Notes") { NSWorkspace.shared.open(releaseNotes) }
                .help(build.channel == .development ? "Show the latest changes on GitHub" : "Show what changed in \(build.version)")
            Button("Report a Problem") { NSWorkspace.shared.open(Self.repository.appendingPathComponent("issues/new")) }
                .help("Open a new issue on GitHub; paste the version info from the copy button above")
        }
        .buttonStyle(.glass)
    }

    private var releaseNotes: URL {
        build.channel == .development
            ? Self.repository.appendingPathComponent("commits/main")
            : Self.repository.appendingPathComponent("releases/tag/v\(build.version)")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Text(["macOS \(BuildInfo.macOS)", BuildInfo.architecture, "SwiftNIO"].joined(separator: "  ·  "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("mostlygino.com", destination: Self.website)
                Link("Source", destination: Self.repository)
                    .help("Sekisho's source code, AGPL-3.0-or-later")
                Link("Feedback", destination: Self.repository.appendingPathComponent("issues/new"))
                    .help("Report a problem or suggest something")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.brass)
            VStack(spacing: 3) {
                Text("Nothing Sekisho records leaves this Mac. Its certificate's key never does either.")
                Text("© 2026 \(Self.developer). Code under AGPL-3.0-or-later;")
                Text("the name, icon and artwork are reserved.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ChannelTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: Build info

/// What this copy of Sekisho is. Commit, date and channel are stamped into Info.plist by make-app.sh.
struct BuildInfo {
    enum Channel: String { case development = "Development", beta = "Beta", release = "Release" }

    let version: String
    let number: String
    let channel: Channel
    let commit: String?
    let date: Date?

    static let current: BuildInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = info["SekishoCommit"] as? String
        return BuildInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "dev",
            number: info["CFBundleVersion"] as? String ?? "?",
            channel: Channel(rawValue: info["SekishoChannel"] as? String ?? "") ?? .development,
            commit: commit == "unknown" || commit?.isEmpty == true ? nil : commit,
            date: (info["SekishoBuildDate"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        )
    }()

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    static var architecture: String {
        #if arch(arm64)
        "Apple silicon"
        #else
        "Intel"
        #endif
    }

    /// Plain text for a bug report.
    func report(checkpoint: String) -> String {
        let channelName = channel == .release ? "" : " \(channel.rawValue)"
        var lines = ["Sekisho \(version)\(channelName) (build \(number))"]
        if let commit { lines.append("Commit \(commit)") }
        if let date { lines.append("Built \(date.formatted(.iso8601))") }
        lines.append("Checkpoint: \(checkpoint)")
        lines.append("macOS \(Self.macOS), \(Self.architecture)")
        return lines.joined(separator: "\n")
    }
}

// MARK: Ground

/// Linen: the window ground with a faint weave, too light to read as a pattern.
private struct LinenGround: View {
    var body: some View {
        Color.ground.overlay {
            Canvas { context, size in
                var seed: UInt64 = 0x5E15
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
                }
                // Long threads, mostly along the weave, a few slubs.
                for _ in 0..<140 {
                    let horizontal = next() < 0.5
                    let start = CGPoint(x: next() * size.width, y: next() * size.height)
                    let length = 14 + next() * 40
                    let end = horizontal ? CGPoint(x: start.x + length, y: start.y + (next() - 0.5) * 2)
                                         : CGPoint(x: start.x + (next() - 0.5) * 2, y: start.y + length)
                    var thread = Path()
                    thread.move(to: start)
                    thread.addLine(to: end)
                    context.stroke(thread, with: .color(.primary.opacity(0.025 + next() * 0.03)), lineWidth: 0.4 + next() * 0.8)
                }
            }
            .accessibilityHidden(true)
        }
    }
}
