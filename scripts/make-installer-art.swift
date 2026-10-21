// make-installer-art.swift <outdir> <version>
// Draws the DMG window background and the Installer side art, at 1x and 2x, in turned brass (DESIGN.md).
//
// The DMG ground sits at brass #947030 where Finder writes the icon names: Finder draws them black in light mode
// and white in dark mode, and that one tone gives both 4.5:1. Engine turning rings the middle, the edges fall
// away into dark bronze, and the drag gesture is a single-track line with the tablet riding it: the pass a
// driver must hold to enter the section, as the icon has it.
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "build/installer-art")
let version = args.count > 2 ? args[2] : "0.1.0"
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let icon = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Renders `draw` into a PNG at `scale`, in points with a top-left origin.
func render(_ name: String, size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: CGPoint, align: NSTextAlignment = .center, width: CGFloat = 600,
          kern: CGFloat = 0, shadow: NSColor? = nil) {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style, .kern: kern]
    if let shadow {
        let s = NSShadow(); s.shadowColor = shadow; s.shadowOffset = NSSize(width: 0, height: -0.8); s.shadowBlurRadius = 0
        attrs[.shadow] = s
    }
    let x = align == .center ? p.x - width / 2 : p.x
    NSAttributedString(string: s, attributes: attrs).draw(in: CGRect(x: x, y: p.y, width: width, height: font.pointSize * 1.6))
}

/// Engine turning: fine concentric rings, as a lathe leaves on turned brass; alternate rings catch the light.
func turning(_ cg: CGContext, center c: CGPoint, from r0: CGFloat, to r1: CGFloat) {
    var r = r0
    var i = 0
    while r < r1 {
        let fade = 1 - (r - r0) / (r1 - r0)
        cg.setStrokeColor((i % 2 == 0 ? NSColor.white : hex(0x2A1E0C)).withAlphaComponent(0.045 * fade).cgColor)
        cg.setLineWidth(0.7)
        cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        r += 1.6; i += 1
    }
}

/// Fine grain in the metal; seeded so every build draws the same.
func grain(_ cg: CGContext, in r: CGRect, count: Int, alpha: CGFloat) {
    var seed: UInt64 = 0x7365_6B69_7368_6F
    func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    for _ in 0..<count {
        let p = CGPoint(x: r.minX + next() * r.width, y: r.minY + next() * r.height)
        let d = 0.5 + next() * 1.2
        cg.setFillColor((next() > 0.5 ? NSColor.white : hex(0x24180A)).withAlphaComponent(alpha * next()).cgColor)
        cg.fillEllipse(in: CGRect(x: p.x, y: p.y, width: d, height: d))
    }
}

/// The tablet: a turned brass disc with its triangle cut through, bevelled, lit from the top left.
func tablet(_ cg: CGContext, center c: CGPoint, radius r: CGFloat, ground: NSColor) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    cg.setFillColor(hex(0xB8893F).cgColor)
    cg.fillEllipse(in: disc)
    cg.restoreGState()
    cg.saveGState()
    cg.addEllipse(in: disc); cg.clip()
    let brass = CGGradient(colorsSpace: space, colors: [hex(0xF2CD7A).cgColor, hex(0xD9A94F).cgColor, hex(0x9E7330).cgColor] as CFArray, locations: [0, 0.5, 1])!
    cg.drawLinearGradient(brass, start: CGPoint(x: disc.minX, y: disc.minY), end: CGPoint(x: disc.maxX, y: disc.maxY), options: [])
    turning(cg, center: c, from: 1, to: r)
    cg.restoreGState()
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor); cg.setLineWidth(0.8)
    cg.strokeEllipse(in: disc.insetBy(dx: 0.5, dy: 0.5))
    // The cut-out triangle, showing the ground through it, with a dark inner lip.
    let t = r * 0.52
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: c.x, y: c.y - t)); tri.addLine(to: CGPoint(x: c.x + t * 0.92, y: c.y + t * 0.6)); tri.addLine(to: CGPoint(x: c.x - t * 0.92, y: c.y + t * 0.6)); tri.closeSubpath()
    cg.addPath(tri); cg.setFillColor(ground.cgColor); cg.fillPath()
    cg.addPath(tri); cg.setStrokeColor(hex(0x3A2810, 0.75).cgColor); cg.setLineWidth(1.1); cg.strokePath()
}

// MARK: DMG window, 660 × 420 points

let dmg = CGSize(width: 660, height: 420)
let label = hex(0x947030)
for (name, scale) in [("dmg-background.png", 1.0), ("dmg-background@2x.png", 2.0)] {
    render(name, size: dmg, scale: scale) { cg in
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let center = CGPoint(x: 330, y: 205)
        // Ground: the label tone across the icons' band, dark bronze at the edges.
        let ground = CGGradient(colorsSpace: space, colors: [hex(0x9C783A).cgColor, label.cgColor, hex(0x5A4119).cgColor, hex(0x2A1E0C).cgColor] as CFArray,
                                locations: [0, 0.44, 0.84, 1])!
        cg.drawRadialGradient(ground, startCenter: center, startRadius: 0, endCenter: center, endRadius: 440, options: [.drawsAfterEndLocation])
        turning(cg, center: center, from: 40, to: 330)
        grain(cg, in: CGRect(origin: .zero, size: dmg), count: 2400, alpha: 0.09)
        // One soft band of window light across the top, as on the icon.
        cg.saveGState()
        let sheen = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.11).cgColor,
                                                            NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.5, 1])!
        cg.drawLinearGradient(sheen, start: CGPoint(x: 100, y: -50), end: CGPoint(x: 290, y: 140), options: [])
        cg.restoreGState()

        // Title, engraved: a lit lower lip.
        text("Sekisho", .systemFont(ofSize: 26, weight: .semibold), .white, at: CGPoint(x: 330, y: 32), kern: 0.3, shadow: hex(0x2A1E0C, 0.45))
        text("関所  ·  Stop, read and change every request on its way through", .systemFont(ofSize: 12.5, weight: .medium),
             NSColor.white.withAlphaComponent(0.82), at: CGPoint(x: 330, y: 70))

        // The gesture: a single-track line from the app to Applications, between the icons Finder draws at y = 205.
        let x0: CGFloat = 250, x1: CGFloat = 404, y: CGFloat = 205
        for x in stride(from: x0 + 3, through: x1 - 6, by: 9) {
            cg.setFillColor(hex(0x2A1E0C, 0.55).cgColor)
            cg.fill(CGRect(x: x, y: y - 9, width: 3.2, height: 18))
        }
        for railY in [y - 5, y + 5] {
            cg.setStrokeColor(hex(0x2A1E0C, 0.5).cgColor); cg.setLineWidth(2.6)
            cg.move(to: CGPoint(x: x0, y: railY + 0.8)); cg.addLine(to: CGPoint(x: x1, y: railY + 0.8)); cg.strokePath()
            cg.setStrokeColor(hex(0xF4E2B8, 0.95).cgColor); cg.setLineWidth(1.6)
            cg.move(to: CGPoint(x: x0, y: railY)); cg.addLine(to: CGPoint(x: x1, y: railY)); cg.strokePath()
        }
        // Buffer at the far end: the line runs into Applications.
        cg.setFillColor(hex(0xF4E2B8).cgColor)
        cg.move(to: CGPoint(x: x1 + 14, y: y)); cg.addLine(to: CGPoint(x: x1 + 2, y: y - 10)); cg.addLine(to: CGPoint(x: x1 + 2, y: y + 10)); cg.closePath()
        cg.fillPath()
        tablet(cg, center: CGPoint(x: 316, y: y), radius: 15, ground: label)
        text("Drag to Applications", .systemFont(ofSize: 12, weight: .semibold), NSColor.white.withAlphaComponent(0.94),
             at: CGPoint(x: 328, y: 228), shadow: hex(0x2A1E0C, 0.35))

        // Footer: a ticket-edge rule, then the colophon; clear of the bottom 30 pt in case Finder counts the title bar.
        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor); cg.setLineWidth(0.8)
        cg.setLineDash(phase: 0, lengths: [2, 3])
        for (from, to) in [(120.0, 308.0), (352.0, 540.0)] {
            cg.move(to: CGPoint(x: from, y: 340)); cg.addLine(to: CGPoint(x: to, y: 340)); cg.strokePath()
        }
        cg.setLineDash(phase: 0, lengths: [])
        text("通票", .systemFont(ofSize: 10, weight: .semibold), hex(0xF4E2B8, 0.7), at: CGPoint(x: 330, y: 333), width: 60)
        text("Version \(version)   ·   AGPL-3.0   ·   mostlygino.com", .systemFont(ofSize: 10.5, weight: .regular),
             NSColor.white.withAlphaComponent(0.62), at: CGPoint(x: 330, y: 358))
    }
}

// MARK: Installer, 620 × 418 points; Installer pins it bottom-left behind the step list

let pkg = CGSize(width: 620, height: 418)
for dark in [false, true] {
    for scale in [1.0, 2.0] {
        let name = "installer-\(dark ? "dark" : "light")\(scale == 2 ? "@2x" : "").png"
        render(name, size: pkg, scale: scale) { cg in
            // Only the lower left carries art; the rest stays clear so Installer's own panel reads as usual.
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let tint = dark ? hex(0xD9AE5C) : hex(0x8A6420)
            let glow = CGGradient(colorsSpace: space, colors: [tint.withAlphaComponent(dark ? 0.22 : 0.15).cgColor, tint.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1])!
            cg.drawRadialGradient(glow, startCenter: CGPoint(x: 78, y: 314), startRadius: 0, endCenter: CGPoint(x: 78, y: 314), endRadius: 230, options: [])
            turning(cg, center: CGPoint(x: 78, y: 314), from: 60, to: 150)
            if let icon {
                icon.draw(in: CGRect(x: 26, y: 262, width: 104, height: 104), from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            }
            let ink = dark ? NSColor.white : hex(0x1B1917)
            text("Sekisho 関所", .systemFont(ofSize: 15, weight: .semibold), ink.withAlphaComponent(0.85), at: CGPoint(x: 26, y: 372), align: .left, width: 180)
            text("Version \(version)", .systemFont(ofSize: 10.5), ink.withAlphaComponent(0.55), at: CGPoint(x: 26, y: 392), align: .left, width: 160)
        }
    }
}
print("art in \(out.path)")
