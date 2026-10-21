/*
 THESIS: Sekisho is the single-line tablet: the brass pass a driver must hold to enter a section. Quiet edition:
 the tablet lives in the icon, the record control and the rule tablets; brass is the accent; the rest is macOS.
 OWN-WORLD: Native macOS 26+ (Liquid Glass sidebar and toolbar, SF Pro, SF Mono for data). Brass accent #8A6420
 fill / #7A5A1E and #D9AE5C text; near-system warm grounds #F6F4F0 / #1B1917. Status and interventions keep their colours.
 FORM: chosen by Gino from the five icon options (Tsūhyō 通票, 2026-10-19); toned down the same day.
 */

import AppKit
import SekishoCore
import SwiftUI

@main
struct SekishoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Sekisho", id: "main") {
            MainWindow()
                .environment(Store.shared)
                .defaultAppStorage(Demo.defaults)
                .frame(minWidth: 620, minHeight: 460)
                .tint(.brassFill)
                .containerBackground(Color.ground, for: .window)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { SekishoCommands() }

        Window("Tools", id: "tools") {
            ToolsWindow()
                .environment(Store.shared)
                .defaultAppStorage(Demo.defaults)
                .frame(minWidth: 620, minHeight: 420)
                .tint(.brassFill)
        }
        .defaultSize(width: 1080, height: 640)
        .keyboardShortcut("t", modifiers: [.command, .shift])

        WindowGroup("Compare", id: "diff", for: DiffPair.self) { $pair in
            DiffWindow(pair: pair)
                .environment(Store.shared)
                .defaultAppStorage(Demo.defaults)
                .tint(.brassFill)
        }
        .defaultSize(width: 1200, height: 800)
        .restorationBehavior(.disabled)

        // A request in its own window, by flow id.
        WindowGroup("Request", id: "flow", for: Int.self) { $id in
            FlowWindow(id: id)
                .environment(Store.shared)
                .defaultAppStorage(Demo.defaults)
                .tint(.brassFill)
                .containerBackground(Color.ground, for: .window)
        }
        .defaultSize(width: 1100, height: 760)
        .restorationBehavior(.disabled)

        Window("Welcome to Sekisho", id: "welcome") {
            WelcomeWindow()
                .environment(Store.shared)
                .defaultAppStorage(Demo.defaults)
                .tint(.brassFill)
                .containerBackground(Color.raised, for: .window)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        Window("About Sekisho", id: "about") {
            AboutView()
                .environment(Store.shared)
                .defaultAppStorage(Demo.defaults)
                .tint(.brassFill)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        // Breakpoints get their own window: a sheet would wait behind an open Compose sheet.
        Window("Breakpoint", id: "breakpoint") {
            BreakpointWindow()
                .environment(Store.shared)
                .defaultAppStorage(Demo.defaults)
                .tint(.brassFill)
        }
        .defaultSize(width: 760, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(Store.shared)
                .defaultAppStorage(Demo.defaults)
                .tint(.brassFill)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `kill`, `pkill` and logout send SIGTERM: quit properly, so the macOS proxy is put back.
    private var terminate: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `defaults write dev.mostlygino.sekisho appearance dark` (or -appearance dark) forces one appearance,
        // for screenshots of both.
        switch Demo.appearance ?? UserDefaults.standard.string(forKey: "appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.showMainWindow()

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminate = source
        MainActor.assumeIsolated { Store.shared.launch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Store.shared.shutdown() }
    }

    /// Sessions and HAR files from Finder, the Dock or `open`.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            // Stray launch arguments (`-demo -demoWindow compare` reads as a flag, a value and a "file") are not files.
            for url in urls where !url.isFileURL || FileManager.default.fileExists(atPath: url.path) { Store.shared.open(url) }
            Self.showMainWindow()
        }
    }

    /// Launched to open a file, SwiftUI does not open the main window by itself: open it from the Window menu.
    @MainActor static func showMainWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.title == "Sekisho" }),
                  let menu = NSApp.windowsMenu, let item = menu.items.first(where: { $0.title == "Sekisho" }) else { return }
            menu.performActionForItem(at: menu.index(of: item))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SekishoCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Sekisho") { openWindow(id: "about") }
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Sekisho…") { openWindow(id: "welcome") }
            Divider()
            Button("Sekisho on GitHub") { NSWorkspace.shared.open(AboutView.repository) }
            Button("Report a Problem…") { NSWorkspace.shared.open(AboutView.repository.appendingPathComponent("issues/new")) }
            Divider()
            Button("mostlygino.com") { NSWorkspace.shared.open(AboutView.website) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Compose Request") { Store.shared.composing = .blank }.keyboardShortcut("n")
        }
        CommandGroup(after: .newItem) {
            Button("Open Session or HAR…") { Store.shared.openFile() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Session…") { Store.shared.saveSession(Store.shared.visibleFlows) }.keyboardShortcut("s")
            Button("Save Selected as Session…") { Store.shared.saveSession(Store.shared.selectedFlows) }
                .keyboardShortcut("s", modifiers: [.command, .option])
        }
        CommandGroup(after: .saveItem) {
            Button("Export Selected as HAR…") { Store.shared.exportHAR(Store.shared.selectedFlows) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export Visible as HAR…") { Store.shared.exportHAR(Store.shared.visibleFlows) }
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy as cURL") { Store.shared.copyCurl(Store.shared.selectedFlows) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Copy URL") { Store.shared.copy(Store.shared.selectedFlows.map(\.url).joined(separator: "\n")) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandMenu("Traffic") {
            Button("Repeat") { Store.shared.repeatRequests(Store.shared.selectedFlows) }.keyboardShortcut("r")
            Button("Edit and Repeat…") { if let f = Store.shared.selectedFlow { Store.shared.composing = f } }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Compare Selected") {
                let s = Store.shared.selectedFlows
                if s.count == 2 { openWindow(id: "diff", value: DiffPair(a: s[0].id, b: s[1].id)) }
            }
            .keyboardShortcut("y")
            Divider()
            Button(Store.shared.recording ? "Pause Recording" : "Resume Recording") { Store.shared.recording.toggle() }
                .keyboardShortcut("p")
            Button(Store.shared.systemProxyOn ? "Turn Off macOS Proxy" : "Turn On macOS Proxy") {
                Store.shared.setSystemProxy(!Store.shared.systemProxyOn)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Clear") { Store.shared.clear() }.keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Tools…") { openWindow(id: "tools") }
            Divider()
            Button("Command Palette…") { CommandPalette.shared.toggle() }.keyboardShortcut("k")
        }
    }
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Upstream", systemImage: "arrow.up.forward.circle", value: "upstream") {
                Form { Section { UpstreamProxySettings() } }.formStyle(.grouped)
            }
            Tab("Certificate", systemImage: "checkmark.seal", value: "certificate") { CertificateSettings() }
        }
        .scenePadding(.top)
        .frame(width: 580, height: 500)
    }
}

private struct GeneralSettings: View {
    @Environment(Store.self) private var store
    @State private var portText = ""

    private var newPort: Int? {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(p), p != store.port else { return nil }
        return p
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: $portText)
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .onSubmit { if let p = newPort { store.port = p } }
                        Button("Apply") { if let p = newPort { store.port = p } }.disabled(newPort == nil)
                    }
                }
            } header: {
                Text("Proxy")
            } footer: {
                Text(store.allowLAN ? "Listening on this Mac's network addresses too." : "Listening on 127.0.0.1 only; other devices cannot reach it. Ports 1024 to 65535.")
                    .foregroundStyle(.secondary)
            }
            Section("Devices on the Network") {
                Toggle("Allow phones and other devices on my network", isOn: $store.allowLAN)
                if store.allowLAN {
                    Label("Anyone on this network can now send traffic through this Mac. Only private addresses (192.168.x, 10.x, 172.16-31.x) are served. Turn it off when you are done.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusClient)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(LocalAddresses.ipv4(), id: \.address) { a in
                        LabeledContent(a.interface) { Text("\(a.address):\(String(store.port))").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    }
                    Text("On the device: set the Wi-Fi HTTP proxy to one of these addresses, open http://sekisho.ca/ca.pem in its browser, install the profile and trust it (iOS: Settings > General > About > Certificate Trust Settings).")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(store.port) }
    }
}

private struct CertificateSettings: View {
    @Environment(Store.self) private var store
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Sekisho CA") {
                    Label(store.caTrusted ? "Trusted on this Mac" : "Not trusted yet",
                          systemImage: store.caTrusted ? "checkmark.seal.fill" : "seal")
                        .foregroundStyle(store.caTrusted ? Color.statusOK : .secondary)
                }
                if store.caTrusted {
                    LabeledContent("Trust") { Button("Remove…", role: .destructive) { confirmRemove = true } }
                } else {
                    LabeledContent("Trust") { Button("Trust Certificate…") { store.installCertificate() } }
                }
                LabeledContent("Certificate file") { Button("Save…") { store.exportCertificate() } }
                LabeledContent("iOS Simulators") {
                    Button("Install") { store.installInSimulators() }.help("Adds the certificate to every booted iOS Simulator with simctl")
                }
            } footer: {
                Text("The private key stays in ~/Library/Application Support/Sekisho and never leaves this Mac. Other devices can fetch the certificate from http://sekisho.ca/ca.pem through the proxy.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refreshTrust() }
        .confirmationDialog("Remove trust and delete the key?", isPresented: $confirmRemove) {
            Button("Remove Trust and Delete Key", role: .destructive) { store.removeCertificate() }
        } message: {
            Text("HTTPS can no longer be decrypted until Sekisho makes a new certificate and you trust it again. Devices that trust the old one keep doing so until you remove it there.")
        }
    }
}

/// Send Sekisho's own outgoing traffic through another proxy. The password goes to the Keychain.
struct UpstreamProxySettings: View {
    @Environment(Store.self) private var store
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var password = ""
    @State private var bypass = ""
    @State private var enabled = false

    var body: some View {
        Toggle("Send traffic through another proxy", isOn: $enabled)
            .onAppear(perform: load)
            .onChange(of: enabled) { _, on in if !on { store.rules.upstreamProxy?.enabled = false } }
        if enabled {
            TextField("Host", text: $host, prompt: Text("proxy.example.com"))
            TextField("Port", text: $port, prompt: Text("8080"))
            TextField("User", text: $user, prompt: Text("Optional"))
            SecureField("Password", text: $password, prompt: Text("Kept in the Keychain"))
            TextField("Bypass", text: $bypass, prompt: Text("localhost, *.local"))
            HStack {
                Text("HTTPS and tunnels go through it with CONNECT; plain HTTP in absolute form. Not used for the hosts in Bypass.")
                    .foregroundStyle(.secondary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Apply") { apply() }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || !(1...65535).contains(Int(port) ?? 0))
            }
        }
    }

    private func load() {
        let p = store.rules.upstreamProxy
        enabled = p?.enabled ?? false
        host = p?.host ?? ""
        port = p.map { String($0.port) } ?? "8080"
        user = p?.username ?? ""
        password = Keychain.upstreamPassword(for: user) ?? ""
        bypass = (p?.bypass ?? ["localhost", "127.0.0.1", "*.local"]).joined(separator: ", ")
    }

    private func apply() {
        guard enabled, !host.isEmpty, let p = Int(port), (1...65535).contains(p) else {
            store.rules.upstreamProxy?.enabled = false
            return
        }
        var proxy = UpstreamProxy(host: host.trimmingCharacters(in: .whitespaces), port: p)
        proxy.username = user
        proxy.bypass = bypass.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Keychain.setUpstreamPassword(password, for: user)
        store.rules.upstreamProxy = proxy
    }
}
