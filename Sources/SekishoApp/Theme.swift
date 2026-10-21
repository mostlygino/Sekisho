import AppKit
import SekishoCore
import SwiftUI

// Tsūhyō, quiet edition (DESIGN.md): macOS glass and system chrome first, brass as the one accent for what you can
// act on, a warm hint in the grounds. Status and interventions keep their own colours: they are data, not decoration.
extension Color {
    /// Brass as text and outlines: 5.5:1 on linen, 9.1:1 on the dark ground.
    static let brass = Color.dynamic(light: 0x7A5A1E, dark: 0xD9AE5C)
    /// Brass as a fill under white labels (AccentColor matches): 5.35:1; 3.5:1 against the dark ground.
    static let brassFill = Color.dynamic(light: 0x8A6420, dark: 0x8A6420)
    /// The work surfaces: near-system neutrals with a little warmth.
    static let ground = Color.dynamic(light: 0xF6F4F0, dark: 0x1B1917)
    static let raised = Color.dynamic(light: 0xFCFBF9, dark: 0x221F1D)
    static let rule = Color.dynamic(light: 0xE4E0D8, dark: 0x36322E)
    /// The engraving fill on brass (7.6:1 on brass).
    static let engraving = Color(red: 0.165, green: 0.11, blue: 0.055)

    // Status: a dot beside the code, never colour alone.
    static let statusOK = Color.dynamic(light: 0x1E8A5A, dark: 0x3DB27A)
    static let statusRedirect = Color.dynamic(light: 0x6B7785, dark: 0x8D99A8)
    static let statusClient = Color.dynamic(light: 0xB87F00, dark: 0xE2A400)
    static let statusFailed = Color.dynamic(light: 0xC8352B, dark: 0xE5533F)

    // Interventions: what Sekisho did to an exchange.
    static let holdRed = Color.dynamic(light: 0xC8352B, dark: 0xE5533F)
    static let localAmber = Color.dynamic(light: 0xB87F00, dark: 0xE2A400)
    static let remoteBlue = Color.dynamic(light: 0x2C66B8, dark: 0x5B93E0)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

/// Turned brass, lit from the window high on the left, as the icon is.
let brassGradient = LinearGradient(colors: [Color(red: 0.95, green: 0.80, blue: 0.48), Color(red: 0.85, green: 0.66, blue: 0.31),
                                            Color(red: 0.62, green: 0.45, blue: 0.19)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
/// Brass left alone: tarnished, for anything switched off.
let patinaGradient = LinearGradient(colors: [Color(red: 0.62, green: 0.58, blue: 0.50), Color(red: 0.42, green: 0.39, blue: 0.33)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)

extension Intervention {
    var label: String {
        switch self {
        case .hold: "Held at a breakpoint"
        case .mapLocal: "Answered by Map Local"
        case .mapRemote: "Sent elsewhere by Map Remote"
        case .block: "Blocked"
        case .aborted: "Aborted"
        case .edited: "Edited"
        case .replay: "Repeated or composed"
        case .script: "Changed by a script"
        case .throttled: "Slowed by Network Conditions"
        case .spoofed: "Sent to another address by DNS Spoofing"
        }
    }
    var symbol: String {
        switch self {
        case .hold: "hand.raised.fill"
        case .mapLocal: "doc.fill"
        case .mapRemote: "arrow.triangle.branch"
        case .block: "nosign"
        case .aborted: "xmark.octagon.fill"
        case .edited: "pencil"
        case .replay: "arrow.clockwise"
        case .script: "curlybraces"
        case .throttled: "tortoise.fill"
        case .spoofed: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
    /// Edits and repeats are the user's own hand, so neutral.
    var color: Color {
        switch self {
        case .hold, .block, .aborted: .holdRed
        case .mapLocal: .localAmber
        case .mapRemote, .spoofed: .remoteBlue
        case .script, .throttled: .localAmber
        case .edited, .replay: .secondary
        }
    }
    static let order: [Intervention] = [.block, .aborted, .hold, .script, .mapLocal, .mapRemote, .spoofed, .throttled, .edited, .replay]
}

/// A dot beside the status code: green 2xx, slate 3xx, amber 4xx, red 5xx and failures, an empty ring while waiting.
struct StatusDot: View {
    let color: Color?

    init(_ flow: Flow) {
        if flow.error != nil || flow.interventions.contains(.block) || flow.interventions.contains(.aborted) { color = .statusFailed; return }
        switch flow.status ?? 0 {
        case 200..<300, 101: color = .statusOK
        case 300..<400: color = .statusRedirect
        case 400..<500: color = .statusClient
        case 500...: color = .statusFailed
        default: color = nil
        }
    }

    var body: some View {
        Group {
            if let color {
                Circle().fill(color).frame(width: 7, height: 7)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1).frame(width: 7, height: 7)
            }
        }
        .frame(width: 10)
        .accessibilityHidden(true)
    }
}

/// A brass tablet with a number engraved in it. A small enamel ring says which tool it belongs to;
/// switched off, the brass is left to tarnish.
struct TabletPlate: View {
    let number: Int
    let mark: Color
    let on: Bool

    var body: some View {
        ZStack {
            Circle().fill(on ? brassGradient : patinaGradient)
            Circle().strokeBorder(mark.opacity(on ? 0.9 : 0.35), lineWidth: 1.6).padding(2)
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .black.opacity(0.35)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            Text("\(number)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.engraving.opacity(on ? 1 : 0.7))
                // Engraved: a lit lower lip.
                .shadow(color: .white.opacity(0.45), radius: 0, y: 0.6)
        }
        .frame(width: 20, height: 20)
        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.8)
        .accessibilityLabel("\(number), \(on ? "on" : "off")")
    }
}

/// The record control, in the language every Mac app uses: a red dot while recording, a pause sign when not. One
/// line, so the state reads at a glance; the symbol swaps with the system's replace effect (off with Reduce Motion).
struct RecordControl: View {
    let recording: Bool
    let inFlight: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: recording ? "record.circle.fill" : "pause.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, recording ? Color.statusFailed : Color.secondary)
                .font(.system(size: 15, weight: .regular))
                .contentTransition(.symbolEffect(.replace))
            Text(recording ? "Recording" : "Paused")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(recording ? .primary : .secondary)
            if recording, inFlight > 0 {
                Text(String(inFlight))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .help("\(inFlight) in flight")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
        .accessibilityValue(recording ? (inFlight > 0 ? "On, \(inFlight) in flight" : "On") : "Paused")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The tablet's outline: a disc with its triangle cut out (fill with eoFill).
struct TabletShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(ellipseIn: rect)
        let c = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.03), r = rect.width * 0.24
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addLine(to: CGPoint(x: c.x + r * 0.866, y: c.y + r * 0.5))
        p.addLine(to: CGPoint(x: c.x - r * 0.866, y: c.y + r * 0.5))
        p.closeSubpath()
        return p
    }
}

/// The tablet as the app icon draws it: polished brass, its triangle cut through (`Resources/tablet.png`, cut from
/// the icon). Off, the brass is left to tarnish.
struct TabletMark: View {
    var on = true
    private static let image = Bundle.main.url(forResource: "tablet", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high)
                .saturation(on ? 1 : 0.15).brightness(on ? 0 : -0.1)
        } else {
            TabletShape().fill(on ? brassGradient : patinaGradient, style: FillStyle(eoFill: true))
        }
    }
}

enum Formats {
    static let time: DateFormatter = {
        let f = DateFormatter()
        // POSIX locale, or a 12-hour system setting rewrites HH.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func bytes(_ n: Int) -> String {
        n < 1000 ? "\(n) B" : ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func duration(_ t: TimeInterval?) -> String {
        guard let t else { return "" }
        return t < 1 ? "\(Int((t * 1000).rounded())) ms" : String(format: "%.2f s", t)
    }
}
