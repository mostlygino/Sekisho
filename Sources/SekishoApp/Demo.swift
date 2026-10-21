import Foundation
import SekishoCore

/// `-demo`: Sekisho with a recorded session and example rules, for screenshots and trying it out. Nothing of this
/// Mac's is touched: no listener, no certificate on disk or in the keychain, no macOS proxy, and settings in their
/// own domain (dev.mostlygino.sekisho.demo), wiped at every demo launch. Hosts are documentation names and
/// addresses only (example.com, example.net, example.org, 192.0.2.x).
///
///   open -n Sekisho.app --args -demo -demoAppearance dark -demoWindow tools:Breakpoints
///
/// -demoAppearance light|dark
/// -demoWindow tools[:<tool name>] | compose | compare | breakpoint | settings | about | welcome | palette[:<query>] | request
/// -demoStation 1...5  the welcome walk's station (with -demoWindow welcome)
/// -demoSelect <row|path> the row selected in the list (default 3), or the first whose path starts with it
/// -demoShot "<spec>"    anything else, in ScreenshotDirector's spec (req=, resp=, body=, layout=, size=, ...)
enum Demo {
    static let on = ProcessInfo.processInfo.arguments.contains("-demo")
    static let suite = "dev.mostlygino.sekisho.demo"

    /// Where Sekisho keeps its settings: its own domain normally, a throwaway one in demo mode.
    static let defaults: UserDefaults = {
        guard on, let d = UserDefaults(suiteName: suite) else { return .standard }
        d.removePersistentDomain(forName: suite)
        return d
    }()

    /// Compose history and the like: Application Support normally, a temporary folder in demo mode.
    static var support: URL {
        on ? FileManager.default.temporaryDirectory.appendingPathComponent("Sekisho demo", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sekisho", isDirectory: true)
    }

    static func value(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var appearance: String? { on ? value("-demoAppearance") : nil }

    /// The bundled session (Resources/Demo.sekisho), or the repo's copy under `swift run`.
    static var session: URL? {
        if let url = Bundle.main.url(forResource: "Demo", withExtension: "sekisho") { return url }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/demo/Sekisho demo.sekisho")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    /// What the demo opens with, as a ScreenshotDirector spec.
    static var shot: String {
        var parts: [String] = []
        if let session { parts.append("open=\(session.path)") }
        parts.append("select=\(value("-demoSelect") ?? "3")")
        if let station = value("-demoStation") { parts.append("station=\(station)") }
        if let window = value("-demoWindow") {
            switch window {
            case "compare": parts.append("window=diff:3,4")
            case "compose": parts.append("window=compose")
            case "request": parts.append("window=flow:\(value("-demoSelect") ?? "3")")
            case "tools": parts.append("window=tools:SSL Proxying")
            default: parts.append("window=\(window)")
            }
        }
        if let extra = value("-demoShot") { parts.append(extra) }
        return parts.joined(separator: ";")
    }

    /// One rule or more in every tool, matching the session's hosts.
    static var rules: ProxyRules {
        var r = ProxyRules()
        r.sslProxying = ["*.example.com"]
        r.sslExclude = ["bank.example.org"]
        r.blocked = ["ads.example.net"]
        r.breakpoints = [BreakpointRule(pattern: "https://api.example.com/v2/cart", request: false, response: true)]
        var script = ScriptRule(pattern: "https://api.example.com/v2/products/*", name: "Add debug header")
        script.code = """
        function onRequest(context, url, request) {
          request.headers["X-Debug"] = "sekisho";
          return request;
        }
        """
        script.response = false
        r.scripts = [script]
        var flags = MapLocalRule(pattern: "https://api.example.com/v2/flags*", body: "{\n  \"newCheckout\": true,\n  \"darkMode\": \"auto\"\n}")
        flags.contentType = "application/json"
        r.mapLocal = [flags]
        var remote = MapRemoteRule(pattern: "https://api.example.com/v3/*", destination: "http://localhost:3000")
        remote.enabled = false
        r.mapRemote = [remote]
        r.dnsSpoofing = [DNSRule(host: "staging.example.com", address: "192.0.2.10")]
        r.throttles = [ThrottleRule(pattern: "https://api.example.com/v2/recommendations*", latencyMs: 300, downKbps: 780, upKbps: 330)]
        var reverse = ReverseProxyRule(localPort: 8888, remoteHost: "api.example.com", remotePort: 443, tls: true)
        reverse.enabled = false
        r.reverseProxies = [reverse]
        return r
    }
}
