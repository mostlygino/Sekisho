import AppKit
import SekishoCore
import SwiftUI

/// Puts Sekisho in a given state for screenshots and visual review, without a mouse:
///
///   defaults write dev.mostlygino.sekisho shot "open=docs/demo/Sekisho demo.sekisho;select=3;req=Headers;resp=Body;window=tools:Scripting"
///
/// Read once at launch, then removed. `select` counts rows in the list from 1. Windows: about, settings, compose,
/// breakpoint, palette:<query>, tools:<tool>, flow:<row>, diff:<row>,<row>. Also layout=stacked|sideBySide,
/// body=<Pretty|Tree|Text|Hex|Preview>, chips=JSON,HTTPS, search=<text>, maximise=request|response,
/// size=<width>,<height>, sidebar=hidden, recording=off.
@MainActor
enum ScreenshotDirector {
    static func snap(into folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible || window.isMiniaturized == false {
            guard let view = window.contentView?.superview ?? window.contentView, view.bounds.width > 50 else { continue }
            view.appearance = NSApp.effectiveAppearance
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window-\(window.windowNumber)" : window.title.replacingOccurrences(of: "/", with: "_")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
        }
    }

    static func run(_ spec: String, store: Store) {
        var steps: [(String, String)] = []
        for part in spec.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            steps.append((kv[0], kv.count > 1 ? kv[1] : ""))
        }
        for (key, value) in steps where key == "open" {
            store.open(URL(fileURLWithPath: (value as NSString).expandingTildeInPath))
        }
        /// A row number from 1, or a path: `select=/live` picks the first request whose path starts with it.
        func row(_ n: String) -> Flow? {
            if n.hasPrefix("/") { return store.visibleFlows.first { $0.path.hasPrefix(n) } }
            guard let i = Int(n), i >= 1, i <= store.visibleFlows.count else { return nil }
            return store.visibleFlows[i - 1]
        }
        for (key, value) in steps {
            switch key {
            case "snap":
                // Draw every window into PNGs in this folder, whether or not it is on a screen.
                let folder = value.isEmpty ? "/tmp/sekisho-snaps" : value
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { snap(into: folder) }
            case "select": if let f = row(value) { store.reveal(f.id) }
            case "req": store.shotRequestTab = value
            case "resp": store.shotResponseTab = value
            case "body": store.shotBodyMode = value
            case "maximise": store.shotMaximise = value
            case "layout": Demo.defaults.set(value, forKey: "inspectorLayout")
            case "chips": store.chips = Set(value.split(separator: ",").map(String.init))
            case "search": store.filterText = value
            case "recording": store.recording = value != "off"
            case "station": store.shotWelcomeStation = Int(value).map { $0 - 1 }
            case "size":
                // size=W,H: the main window at this content size, as a tiling window manager would leave it.
                let wh = value.split(separator: ",").compactMap { Double($0) }
                if wh.count == 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        NSApp.windows.first { $0.title == "Sekisho" }?.setContentSize(NSSize(width: wh[0], height: wh[1]))
                    }
                }
            case "sidebar": store.shotSidebarHidden = value == "hidden"
            case "window":
                let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
                switch parts[0] {
                case "about", "tools", "welcome": 
                    if parts[0] == "tools", parts.count > 1, let t = Tool(rawValue: parts[1]) { store.requestedTool = t }
                    PaletteActions.openWindow?(parts[0])
                case "settings": PaletteActions.openSettings?()
                case "compose": store.composing = store.selectedFlow ?? .blank
                case "palette": PaletteSnapshot.show(query: parts.count > 1 ? parts[1] : "")
                case "flow": if parts.count > 1, let f = row(parts[1]) { PaletteActions.openFlow?(f.id) }
                case "diff":
                    let rows = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { row(String($0)) }
                    if rows.count == 2 { PaletteActions.openDiff?(DiffPair(a: rows[0].id, b: rows[1].id)) }
                case "breakpoint":
                    if let f = store.selectedFlow { Task { _ = await store.holdForShot(f) } }
                default: break
                }
            default: break
            }
        }
    }
}
