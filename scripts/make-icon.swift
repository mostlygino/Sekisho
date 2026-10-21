// Renders the Sekisho app icon (and the four options beside it) and writes the icon set.
//
//   swiftc -O scripts/make-icon.swift -o /tmp/sekisho-icon
//   /tmp/sekisho-icon <AppIcon.iconset|AppIcon.appiconset> [--variant <name>] [--brand <folder>] [--preview <folder>]
//
// 関所 (sekisho), the checkpoint on an Edo-era road where every traveller was
// stopped, their pass read and stamped, and sent on. Sekisho is an HTTP proxy
// that does that to traffic, and its interface is a signal box (DESIGN.md):
// recorded traffic is the track, everything Sekisho does to it is a lever. So
// the five options are the objects of a checkpoint and of a signal box:
//
//   teko      梃子    the signal lever: a red enamel lever, steel handle, brass plate
//   heisoku   閉塞器  the block instrument: needle on LINE CLEAR in a mahogany case
//   shingo    信号機  the colour-light signal at night, showing green
//   tsuhyo    通票    the single-line tablet: the brass pass a driver must hold
//   tegata    手形    the traveller's pass: hinoki tablet, sumi 通, the 改 seal
//
// Not drawn with gradients: the same small renderer as Kagami, Kekkai and Shīru.
// Every surface is a height field lit by one window high to the left; normals
// come from the heights, shadows are marched toward the window, and enamel,
// lacquer, glass and metal reflect an analytic room (a shoji window, a dim
// wall, a paper lamp), so reflections bend with the surface by themselves.
// The renderer core below (tokens through softShadow) is Kekkai's, unchanged.
// Run it optimised.
//
//   --variant  tsuhyo (default, the icon), shingo, teko, heisoku, tegata
//   --brand    also write every option, a sheet per option and the options sheet
//   --preview  only the five options at 512 px, for iterating
//
// No SF Symbols: their licence does not allow use in app icons. Characters come
// from Hiragino Mincho as outlines and are rasterised; no font is embedded.

import AppKit

// MARK: Tokens

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let sumi = rgb(0x141214)         // ink, dark surface
let paper = rgb(0xF7F4EE)        // washi, light surface
let surface = rgb(0xF0EDE8)      // brand sheet ground
let shuCG = rgb(0xD9412B)        // 朱, vermilion: Kekkai's colour, kept for the shared core

/// How much a size can carry: fine texture from 256 px, construction detail from 128 px.
enum Detail: Int, Comparable {
    case glyph = 0, mark, full
    init(pixels: CGFloat) { self = pixels <= 64 ? .glyph : pixels <= 160 ? .mark : .full }
    static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }
}

// MARK: Vectors

struct V3 {
    var x: Float, y: Float, z: Float
    static func + (a: V3, b: V3) -> V3 { V3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func * (a: V3, s: Float) -> V3 { V3(x: a.x * s, y: a.y * s, z: a.z * s) }
    static func * (a: V3, b: V3) -> V3 { V3(x: a.x * b.x, y: a.y * b.y, z: a.z * b.z) }
    func dot(_ b: V3) -> Float { x * b.x + y * b.y + z * b.z }
    var normalised: V3 { self * (1 / dot(self).squareRoot()) }
}

func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a * (1 - t) + b * t }
func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }
func smoothstep(_ a: Float, _ b: Float, _ v: Float) -> Float {
    let t = clamp01((v - a) / (b - a))
    return t * t * (3 - 2 * t)
}
func colour(_ hex: UInt32) -> V3 {
    V3(x: Float(hex >> 16 & 0xFF) / 255, y: Float(hex >> 8 & 0xFF) / 255, z: Float(hex & 0xFF) / 255)
}

let white = V3(x: 1, y: 0.97, z: 0.92)
let lacquerBase = colour(0x110D0B)

/// The window. Buffer space: x right, y down, z out of the screen.
let light = V3(x: -0.5, y: -0.62, z: 0.6).normalised
let halfway = (light + V3(x: 0, y: 0, z: 1)).normalised
/// Where shadows fall: away from the window, down and to the right.
let away: (x: Float, y: Float) = {
    let l = (light.x * light.x + light.y * light.y).squareRoot()
    return (-light.x / l, -light.y / l)
}()

// MARK: Fields

/// A square grid of floats, row 0 at the top (as CGBitmapContext stores it).
struct Field {
    let n: Int
    var v: [Float]
    init(_ n: Int, _ fill: Float = 0) { self.n = n; v = [Float](repeating: fill, count: n * n) }
    init(_ n: Int, _ v: [Float]) { self.n = n; self.v = v }
    subscript(x: Int, y: Int) -> Float { v[min(max(y, 0), n - 1) * n + min(max(x, 0), n - 1)] }
    func map(_ f: (Float) -> Float) -> Field { Field(n, v.map(f)) }
}

/// Rasterises a drawing in 1024-unit, y-up coordinates into an n×n coverage field.
func coverage(_ n: Int, _ draw: (CGContext) -> Void) -> Field {
    var bytes = [UInt8](repeating: 0, count: n * n)
    bytes.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.scaleBy(x: CGFloat(n) / 1024, y: CGFloat(n) / 1024)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        draw(ctx)
    }
    return Field(n, bytes.map { Float($0) / 255 })
}

/// Three box passes each way, close to a gaussian of the given radius in pixels.
func blur(_ f: Field, _ radius: Float) -> Field {
    let k = Int((radius / 1.7).rounded())
    guard k >= 1 else { return f }
    let n = f.n, norm = 1 / Float(2 * k + 1)
    var a = f.v, b = f.v
    for _ in 0..<3 {
        for stride in [1, n] {
            a.withUnsafeBufferPointer { s in
                b.withUnsafeMutableBufferPointer { d in
                    for line in 0..<n {
                        let base = stride == 1 ? line * n : line
                        func at(_ i: Int) -> Float { s[base + min(max(i, 0), n - 1) * stride] }
                        var sum: Float = 0
                        for i in -k...k { sum += at(i) }
                        for i in 0..<n {
                            d[base + i * stride] = sum * norm
                            sum += at(i + k + 1) - at(i - k)
                        }
                    }
                }
            }
            swap(&a, &b)
        }
    }
    return Field(n, a)
}

/// Moves a field by whole pixels (right and down positive), edges clamped.
func shifted(_ f: Field, _ dx: Float, _ dy: Float) -> Field {
    let n = f.n, ox = Int(dx.rounded()), oy = Int(dy.rounded())
    var out = Field(n)
    for y in 0..<n { for x in 0..<n { out.v[y * n + x] = f[x - ox, y - oy] } }
    return out
}

/// The shadow an object casts on the ground, and the tight contact shadow at its foot.
func shadows(_ cover: Field, _ u: Float, distance: Float = 24, softness: Float = 32) -> (cast: Field, contact: Field) {
    (blur(shifted(cover, away.x * distance * u, away.y * distance * u), softness * u),
     blur(shifted(cover, away.x * 4 * u, away.y * 4 * u), 5 * u))
}

// MARK: Noise, deterministic so every run draws the same icon

struct Random {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(1 << 31)
    }
    mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + (hi - lo) * next() }
}

func hash(_ x: Int, _ y: Int, _ seed: Int) -> Float {
    var h = UInt64(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ seed &* 2147483647)
    h = (h ^ (h >> 13)) &* 1274126177
    h ^= h >> 16
    return Float(h & 0xFFFF) / 65535 * 2 - 1
}

/// Smooth value noise, -1...1, summed over octaves. `cell` is the coarsest feature in pixels.
func fbm(_ n: Int, cell: Float, octaves: Int, seed: Int) -> Field {
    var out = Field(n)
    var amp: Float = 1, size = max(cell, 1), total: Float = 0
    for o in 0..<octaves {
        let s = seed &+ o &* 101
        for y in 0..<n {
            let fy = Float(y) / size, iy = Int(fy.rounded(.down)), ty = smoothstep(0, 1, fy - Float(iy))
            for x in 0..<n {
                let fx = Float(x) / size, ix = Int(fx.rounded(.down)), tx = smoothstep(0, 1, fx - Float(ix))
                let top = hash(ix, iy, s) * (1 - tx) + hash(ix + 1, iy, s) * tx
                let bottom = hash(ix, iy + 1, s) * (1 - tx) + hash(ix + 1, iy + 1, s) * tx
                out.v[y * n + x] += amp * (top * (1 - ty) + bottom * ty)
            }
        }
        total += amp
        amp *= 0.5
        size = max(size / 2, 1)
    }
    return out.map { $0 / total }
}

// MARK: Shapes (1024 units, y up)

/// A character as an outline, centred on the origin, `height` tall.
func kanjiPath(_ character: String, height: CGFloat) -> CGPath {
    let font = CTFontCreateWithName("HiraMinProN-W6" as CFString, height * 1.18, nil)
    var chars = Array(character.utf16), glyphs = [CGGlyph](repeating: 0, count: 1)
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1), let glyph = CTFontCreatePathForGlyph(font, glyphs[0], nil)
    else { fatalError("Hiragino Mincho ProN W6 with \(character) is needed to draw the icon") }
    let box = glyph.boundingBoxOfPath
    var move = CGAffineTransform(translationX: -box.midX, y: -box.midY)
    return glyph.copy(using: &move)!
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

func polar(_ c: CGPoint, _ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r) }

/// The tile, on the macOS grid: 824 in 1024, corner radius about 185.
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)

// MARK: The room every surface reflects

/// Coordinates are canvas fractions, y down. A flat mirror shows the room where
/// it stands (a planar reflection); a tilted surface looks further across it.
struct Room {
    var window: (x0: Float, y0: Float, x1: Float, y1: Float)
    var detail: Detail
    var night = false
    var top = colour(0xDAD8D4), bottom = colour(0x24211F)

    var glow: V3 { night ? colour(0xFFC27A) * 1.9 : V3(x: 1.45, y: 1.41, z: 1.32) }

    func wall(_ ey: Float) -> V3 { mix(top, bottom, smoothstep(-0.15, 1.05, ey)) }

    /// The andon, a paper lamp low on the right: a warm point in the metal.
    func lamp(_ ex: Float, _ ey: Float) -> V3 {
        let dx = ex - 0.95, dy = ey - 0.9
        return colour(0xFFB467) * (1.1 * exp(-(dx * dx + dy * dy) / 0.0006))
    }

    /// What a polished surface sees.
    func sharp(_ ex: Float, _ ey: Float) -> V3 {
        let c = wall(ey) + lamp(ex, ey)
        let w = window, e: Float = 0.004
        let ix = smoothstep(w.x0 - e, w.x0 + e, ex) * smoothstep(w.x1 + e, w.x1 - e, ex)
        let iy = smoothstep(w.y0 - e, w.y0 + e, ey) * smoothstep(w.y1 + e, w.y1 - e, ey)
        let inside = ix * iy
        guard inside > 0 else { return c }
        return mix(c, pane((ex - w.x0) / (w.x1 - w.x0), (ey - w.y0) / (w.y1 - w.y0)), inside)
    }

    /// What a worn or rough surface sees: the window as a broad glow.
    func soft(_ ex: Float, _ ey: Float) -> V3 {
        let w = window
        let dx = (ex - (w.x0 + w.x1) / 2) / ((w.x1 - w.x0) * 0.85)
        let dy = (ey - (w.y0 + w.y1) / 2) / ((w.y1 - w.y0) * 0.85)
        let g = 0.7 * exp(-(dx * dx + dy * dy))
        let lx = ex - 0.95, ly = ey - 0.9
        let lampGlow = colour(0xFFB467) * (0.25 * exp(-(lx * lx + ly * ly) / 0.03))
        return wall(ey) + (night ? colour(0xFFCB85) : white) * g + lampGlow
    }

    /// The shoji: paper glowing in a frame, kumiko in a grid of three by four.
    func pane(_ u: Float, _ v: Float) -> V3 {
        let wood = colour(0x2B2019), f: Float = 0.045
        let fu = smoothstep(f - 0.01, f, u) * smoothstep(1 - f + 0.01, 1 - f, u)
        let fv = smoothstep(f - 0.01, f, v) * smoothstep(1 - f + 0.01, 1 - f, v)
        let cols: Float = detail == .glyph ? 2 : 3, rows: Float = detail == .glyph ? 2 : 4
        let gu = (u - f) / (1 - 2 * f) * cols, gv = (v - f) / (1 - 2 * f) * rows
        let du = abs(gu - gu.rounded()) / cols, dv = abs(gv - gv.rounded()) / rows
        let bar = max(smoothstep(0.016, 0.008, du), smoothstep(0.016, 0.008, dv))
        return mix(wood, mix(glow, wood, bar), fu * fv)
    }
}

/// Where a surface at (fx, fy) with this normal looks, for a viewer straight in front.
func reflected(_ n: V3, _ fx: Float, _ fy: Float, reach: Float) -> (Float, Float) {
    let rz = max(0.08, 2 * n.z * n.z - 1)
    return (fx + 2 * n.z * n.x / rz * reach, fy + 2 * n.z * n.y / rz * reach)
}

func normal(_ h: Field, _ x: Int, _ y: Int) -> V3 {
    let gx = (h[x + 1, y] - h[x - 1, y]) * 0.5, gy = (h[x, y + 1] - h[x, y - 1]) * 0.5
    return V3(x: -gx, y: -gy, z: 1).normalised
}

// MARK: Materials

/// Polished or worn metal: the room, tinted by the metal, plus a highlight from the window.
func metal(_ nrm: V3, _ fx: Float, _ fy: Float, _ room: Room, tint: V3, rough: Float, reach: Float) -> V3 {
    let (ex, ey) = reflected(nrm, fx, fy, reach: reach)
    var env = room.sharp(ex, ey)
    if rough > 0.01 { env = mix(env, room.soft(ex, ey), rough) }
    let nh = max(0, nrm.dot(halfway))
    let spec = (1 - rough) * 0.35 * pow(nh, 140) + rough * 0.22 * pow(nh, 18)
    let fill = tint * (0.05 + 0.1 * max(0, nrm.dot(light)))
    return tint * env + white * spec + fill
}

/// Urushi: near-black, deep, and it reflects the window faintly.
func lacquer(_ nrm: V3, _ fx: Float, _ fy: Float, _ room: Room, shade: Float, base: V3 = lacquerBase) -> V3 {
    let lit = clamp01(nrm.dot(light))
    let diffuse = base * (0.5 + 0.7 * lit) * (1 - 0.75 * shade)
    let (ex, ey) = reflected(nrm, fx, fy, reach: 0.5)
    let f = 0.06 + 0.94 * pow(1 - max(0, nrm.z), 5)
    let nh = max(0, nrm.dot(halfway))
    let env = room.soft(ex, ey) * 0.8 + room.sharp(ex, ey) * 0.2
    return diffuse + env * (f * (1 - 0.6 * shade)) + white * (0.3 * pow(nh, 300))
}

// MARK: Painting

/// Rolls bright values off softly instead of clipping them, so the window keeps its rows.
func tone(_ v: Float) -> Float { v <= 0.82 ? max(0, v) : 0.82 + 0.18 * (1 - exp(-(v - 0.82) / 0.18)) }

func image(_ n: Int, _ shade: (Int, Int) -> (V3, Float)) -> CGImage {
    var rgba = [UInt8](repeating: 0, count: n * n * 4)
    for y in 0..<n {
        for x in 0..<n {
            let (c, a) = shade(x, y), i = (y * n + x) * 4
            rgba[i + 0] = UInt8(tone(c.x) * a * 255)
            rgba[i + 1] = UInt8(tone(c.y) * a * 255)
            rgba[i + 2] = UInt8(tone(c.z) * a * 255)
            rgba[i + 3] = UInt8(clamp01(a) * 255)
        }
    }
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

/// Pixel centre in canvas fractions, y down.
func frac(_ x: Int, _ y: Int, _ n: Int) -> (Float, Float) { ((Float(x) + 0.5) / Float(n), (Float(y) + 0.5) / Float(n)) }

// MARK: Shared renderer pieces

/// A raised line of half-round section: 1 on its crest, 0 at `half` units away.
func bead(_ d: Float, _ half: Float) -> Float {
    let q = d / half
    return q >= 1 ? 0 : (1 - q * q).squareRoot()
}

/// Smooth value noise at a point, -1...1.
func vnoise(_ x: Float, _ y: Float, _ seed: Int) -> Float {
    let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
    let tx = smoothstep(0, 1, x - Float(ix)), ty = smoothstep(0, 1, y - Float(iy))
    let a = hash(ix, iy, seed) * (1 - tx) + hash(ix + 1, iy, seed) * tx
    let b = hash(ix, iy + 1, seed) * (1 - tx) + hash(ix + 1, iy + 1, seed) * tx
    return a * (1 - ty) + b * ty
}

/// Shadows from the window, by marching toward it across a height field in pixels.
func sunShadow(_ h: Field, steps: Int, stride: Float, soft: Float) -> Field {
    let n = h.n, l = (light.x * light.x + light.y * light.y).squareRoot()
    let dx = light.x / l, dy = light.y / l, rise = light.z / l
    var out = Field(n)
    for y in 0..<n {
        for x in 0..<n {
            let h0 = h.v[y * n + x]
            var s: Float = 0
            for k in 1...steps {
                let t = Float(k) * stride
                let over = h[Int(Float(x) + dx * t + 0.5), Int(Float(y) + dy * t + 0.5)] - h0 - t * rise
                if over > 0 { s = max(s, min(1, over / soft)) }
            }
            out.v[y * n + x] = s
        }
    }
    return out
}

// MARK: Shared pieces

/// Jittered cells: a domed grain per cell and a tone for it (gravel, flecks).
func pebble(_ X: Float, _ Y: Float, cell: Float, seed: Int) -> (bump: Float, tone: Float) {
    let gx = X / cell, gy = Y / cell
    let ix = Int(gx.rounded(.down)), iy = Int(gy.rounded(.down))
    var best: Float = 9, tone: Float = 0
    for oy in -1...1 {
        for ox in -1...1 {
            let cx = ix + ox, cy = iy + oy
            let px = Float(cx) + 0.5 + 0.38 * hash(cx, cy, seed), py = Float(cy) + 0.5 + 0.38 * hash(cx, cy, seed + 1)
            let d2 = (gx - px) * (gx - px) + (gy - py) * (gy - py)
            if d2 < best { best = d2; tone = hash(cx, cy, seed + 2) }
        }
    }
    let b = max(0, 1 - best.squareRoot() / 0.72)
    return ((b * (2 - b)).squareRoot(), tone)
}

func occlusion(_ h: Field, _ near: Field, _ wide: Field, _ i: Int, _ u: Float) -> Float {
    1 - 0.45 * clamp01((near.v[i] - h.v[i]) / (2 * u)) - 0.3 * clamp01((wide.v[i] - h.v[i]) / (6 * u))
}

// MARK: Cords and curves (shared with Kekkai)

/// Lays a cord of round section along a polyline (1024 units, y down), keeping
/// whichever surface is higher. It rides on the surface under its centreline;
/// the twist and the fibres are laid in the cord's own coordinates, so they
/// turn with it.
struct Cords {
    let n: Int, u: Float
    var height: Field, mask: Field, ply: Field, fibre: Field, pale: Field
    let ground: Field

    init(ground: Field, u: Float) {
        n = ground.n; self.u = u; self.ground = ground; height = ground
        mask = Field(n); ply = Field(n); fibre = Field(n); pale = Field(n)
    }

    mutating func lay(_ points: [(Float, Float)], half: Float, lift: (Float) -> Float = { _ in 0 },
                      plied: Bool = true, paleness: Float = 0, seed: Int = 0) {
        guard points.count > 1 else { return }
        var lengths: [Float] = [0]
        for j in 1..<points.count {
            let dx = points[j].0 - points[j - 1].0, dy = points[j].1 - points[j - 1].1
            lengths.append(lengths[j - 1] + (dx * dx + dy * dy).squareRoot())
        }
        let total = max(lengths.last!, 1e-3), alpha: Float = 0.9
        for j in 1..<points.count {
            let ax = points[j - 1].0 * u, ay = points[j - 1].1 * u, bx = points[j].0 * u, by = points[j].1 * u
            let vx = bx - ax, vy = by - ay, len2 = max(vx * vx + vy * vy, 1e-6), segLen = lengths[j] - lengths[j - 1]
            let pad = half * u + 2
            let x0 = max(0, Int(min(ax, bx) - pad)), x1 = min(n - 1, Int(max(ax, bx) + pad))
            let y0 = max(0, Int(min(ay, by) - pad)), y1 = min(n - 1, Int(max(ay, by) + pad))
            guard x0 <= x1 && y0 <= y1 else { continue }
            for py in y0...y1 {
                for px in x0...x1 {
                    let fx = Float(px) + 0.5, fy = Float(py) + 0.5
                    let t = clamp01(((fx - ax) * vx + (fy - ay) * vy) / len2)
                    let cx = ax + vx * t, cy = ay + vy * t
                    let dist = ((cx - fx) * (cx - fx) + (cy - fy) * (cy - fy)).squareRoot() / u
                    guard dist < half else { continue }
                    let side: Float = (vx * (fy - ay) - vy * (fx - ax)) > 0 ? 1 : -1
                    let across = side * dist, tt = across / half, round = (1 - tt * tt).squareRoot()
                    let s = lengths[j - 1] + t * segLen
                    var bump: Float = 0, fib: Float = 0
                    if plied {
                        let phase = s / (half * 2.0) + tt * 0.42
                        bump = pow(sin(.pi * (phase - phase.rounded(.down))), 0.6)
                    }
                    let along = s * cos(alpha) + across * sin(alpha), cross = -s * sin(alpha) + across * cos(alpha)
                    fib = vnoise(cross / 0.7, along / 7, 101 + seed)
                    let base = ground[Int(cx), Int(cy)] / u
                    let z = base + lift(s / total) + half * 0.92 * round + (plied ? half * 0.2 * bump * round : 0)
                    let i = py * n + px
                    if z * u > height.v[i] {
                        height.v[i] = z * u
                        mask.v[i] = max(mask.v[i] * (paleness > 0 ? 1 : 0), clamp01((half - dist) * u + 0.5))
                        ply.v[i] = plied ? bump : 0.6
                        fibre.v[i] = fib
                        pale.v[i] = paleness
                    }
                }
            }
        }
    }
}

func bezier(_ p: [(Float, Float)], steps: Int) -> [(Float, Float)] {
    (0...steps).map { k in
        let t = Float(k) / Float(steps), m = 1 - t
        let a = m * m * m, b = 3 * m * m * t, c = 3 * m * t * t, e = t * t * t
        return (a * p[0].0 + b * p[1].0 + c * p[2].0 + e * p[3].0, a * p[0].1 + b * p[1].1 + c * p[2].1 + e * p[3].1)
    }
}

/// Shadows that harden near the caster and soften further away, as a window's do.
func softShadow(_ h: Field, steps: Int, stride: Float, soft: Float, spread: Float) -> Field {
    let n = h.n, l = (light.x * light.x + light.y * light.y).squareRoot()
    let dx = light.x / l, dy = light.y / l, rise = light.z / l
    var out = Field(n)
    for y in 0..<n {
        for x in 0..<n {
            let h0 = h.v[y * n + x]
            var s: Float = 0
            for k in 1...steps {
                let t = Float(k) * stride
                let over = h[Int(Float(x) + dx * t + 0.5), Int(Float(y) + dy * t + 0.5)] - h0 - t * rise
                if over > 0 { s = max(s, min(1, over / (soft + t * spread))) }
            }
            out.v[y * n + x] = s
        }
    }
    return out
}


// MARK: Sekisho

let proceedCG = rgb(0x1E8A5A)    // signal green, "proceed": the product colour (DESIGN.md)

/// Signed distance to a rounded box centred on the origin; negative inside.
func sdBox(_ px: Float, _ py: Float, _ hw: Float, _ hh: Float, _ r: Float) -> Float {
    let qx = abs(px) - hw + r, qy = abs(py) - hh + r
    return min(max(qx, qy), 0) + (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() - r
}

/// A slab's rounded edge: 0 at the outline, 1 once `bevel` inside it.
func slab(_ sd: Float, _ bevel: Float) -> Float {
    let t = clamp01(-sd / bevel)
    return (1 - (1 - t) * (1 - t)).squareRoot()
}

/// Characters rasterised as coverage. Centres in 1024 units, y down; rotation clockwise in radians.
func glyphField(_ n: Int, _ items: [(String, Float, Float, Float, Float)]) -> Field {
    coverage(n) { ctx in
        for (ch, cx, cy, height, turn) in items {
            var t = CGAffineTransform(translationX: CGFloat(cx), y: CGFloat(1024 - cy)).rotated(by: -CGFloat(turn))
            ctx.addPath(kanjiPath(ch, height: CGFloat(height)).copy(using: &t)!)
        }
        ctx.fillPath()
    }
}

/// Angle in degrees from straight up, clockwise positive (buffer space, y down).
func bearing(_ dx: Float, _ dy: Float) -> Float { atan2(dx, -dy) * 180 / .pi }

// MARK: Teko: 梃子, the signal lever

// In a signal box every signal and every set of points is worked by a lever in
// one long frame. Pull a red lever and a signal clears; leave it and it holds.
// Sekisho's tools (hold, map, divert, block) are levers in its interface, so the
// lever is the product: red enamel, a steel handle bright from the signalman's
// cloth, the spring catch beside it, and the brass plate that names the lever.

func renderTeko(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (0.04, 0.03, 0.6, 0.5), detail: d)
    let p0x: Float = 430, p0y: Float = 846, p1x: Float = 612, p1y: Float = 146
    let lx = p1x - p0x, ly = p1y - p0y, L = (lx * lx + ly * ly).squareRoot()
    let ax = lx / L, ay = ly / L, tilt = atan2(lx, -ly)
    let plateS = 0.44 * L
    let plateCX = p0x + ax * plateS, plateCY = p0y + ay * plateS
    let numeral = d >= .mark ? glyphField(n, [("7", plateCX, plateCY, 96, tilt)]) : Field(n)
    let peel = fbm(n, cell: 30 * u, octaves: 3, seed: 21)
    let grit = d == .full ? fbm(n, cell: 1.6 * u, octaves: 2, seed: 23) : Field(n)
    let wear = d == .full ? fbm(n, cell: 22 * u, octaves: 2, seed: 25) : Field(n)
    var h = Field(n), part = [UInt8](repeating: 0, count: n * n), cover = Field(n)
    var acrossF = Field(n), alongF = Field(n)
    // parts: 0 panel, 1 red lever, 2 steel, 3 brass, 4 engraving, 5 slot, 6 cast iron, 7 chipped red (bare iron)
    func lift(_ s: Float) -> Float { 8 + 150 * clamp01(s / L) }
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
            var height = peel.v[i] * 0.7 + grit.v[i] * 0.15, p: UInt8 = 0, c: Float = 1
            // The slot plate the lever rises through, its slot, and two bolts.
            let plate = sdBox(X - p0x, Y - 870, 212, 60, 26)
            if plate < 0 {
                height = 9 * slab(plate, 6) + grit.v[i] * 0.2; p = 6
                if sdBox(X - p0x, Y - 862, 140, 18, 17) < 0 { height = -46; p = 5 }
                for bx: Float in [p0x - 178, p0x + 178] {
                    let r = ((X - bx) * (X - bx) + (Y - 870) * (Y - 870)).squareRoot()
                    if r < 20 { height = 9 + 11 * (1 - (r / 20) * (r / 20)).squareRoot(); p = 6 }
                }
            }
            // The lever, leaning out of the frame toward you.
            let rx = X - p0x, ry = Y - p0y
            let s = rx * ax + ry * ay, across = rx * -ay + ry * ax
            if s > -2 && s < L {
                let t = s / L
                let kind: UInt8 = t < 0.64 ? 1 : 2
                let hw: Float = t < 0.64 ? 58 - 12 * t / 0.64 : t < 0.7 ? 50 : 34
                let lim = s > L - hw ? max(0, hw * hw - (s - (L - hw)) * (s - (L - hw))).squareRoot() : hw
                let a = abs(across)
                if a < lim {
                    let q = a / max(lim, 0.01)
                    let profile = kind == 1 ? 34 * pow(max(0, 1 - pow(q, 4)), 0.5) : hw * 0.9 * (1 - q * q).squareRoot()
                    // A collar where the paint stops: a ring standing a little proud.
                    let collar: Float = t > 0.64 && t < 0.7 ? 6 * bead(abs(t - 0.67) * L, 22) : 0
                    let z = lift(s) + profile + collar
                    if z > height {
                        height = z; p = kind; c = clamp01((lim - a) * u + 0.5)
                        // Paint worn to the iron on the edges, where the signalman's hand and boots catch it.
                        if kind == 1 && d == .full && q > 0.86 && t < 0.3 && wear.v[i] > 0.3 { p = 7; height -= 0.8 }
                    }
                }
                // The spring catch: a rod beside the handle, held by a bracket at the top.
                let cs = s - 0.71 * L, ca = across - 50
                if cs > 0 && cs < 0.25 * L {
                    let ra = abs(ca)
                    if ra < 10 {
                        let z = lift(s) + 10 + 10 * (1 - (ra / 10) * (ra / 10)).squareRoot()
                        if z > height { height = z; p = 2; c = clamp01((10 - ra) * u + 0.5) }
                    }
                }
                if s > 0.935 * L && s < 0.965 * L && across > 0 && across < 56 {
                    let z = lift(s) + 14
                    if z > height { height = z; p = 2; c = 1 }
                }
            }
            // The brass plate, screwed to the lever, its number cut and filled with black wax.
            let ps = s - plateS
            let pb = sdBox(across, ps, 66, 96, 9)
            if pb < 0 {
                var z = lift(s) + 40 + 7 * slab(pb, 4)
                var pp: UInt8 = 3
                if numeral.v[i] > 0.5 { z -= 2.2 * numeral.v[i]; pp = 4 }
                for sy: Float in [-76, 76] {
                    let r = (across * across + (ps - sy) * (ps - sy)).squareRoot()
                    if r < 9 && d >= .mark { z = lift(s) + 47 + 4 * (1 - (r / 9) * (r / 9)).squareRoot(); pp = 3 }
                }
                if z > height { height = z; p = pp; c = 1 }
            }
            part[i] = p
            cover.v[i] = c
            h.v[i] = height * u
            acrossF.v[i] = across
            alongF.v[i] = s
        }
    }
    let shadow = blur(softShadow(h, steps: 44, stride: 4.2 * u, soft: 1.6 * u, spread: 0.05), 1.4 * u)
    let near = blur(h, 4 * u), wide = blur(h, 18 * u)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n)
        var nrm = normal(h, x, y)
        let sh = shadow.v[i], occl = occlusion(h, near, wide, i, u)
        let falloff = 1.06 - 0.14 * (fx * 0.45 + fy * 0.55)
        // Bottle-green frame paint: thick, a little orange peel, glossy where it has been wiped.
        var out = lacquer(nrm, fx, fy, room, shade: sh, base: colour(0x1D4636) * (1 + 0.06 * peel.v[i])) * falloff * occl
        guard part[i] != 0 else { return (out, 1) }
        let soft = V3(x: nrm.x * 0.6, y: nrm.y * 0.6, z: nrm.z).normalised
        var col: V3
        switch part[i] {
        case 1:
            col = lacquer(soft, fx, fy, room, shade: sh, base: colour(0xB52B22) * (1 + 0.05 * peel.v[i]))
        case 7:
            col = metal(nrm, fx, fy, room, tint: colour(0x5E5F60), rough: 0.7, reach: 0.4) * (1 - 0.5 * sh)
        case 2:
            // Steel polished along its length: the streaks run with the lever.
            let streak = d == .full ? vnoise(acrossF.v[i] / 0.9, alongF.v[i] / 46, 61) : 0
            nrm = V3(x: nrm.x + 0.05 * streak * ay, y: nrm.y - 0.05 * streak * ax, z: nrm.z).normalised
            col = metal(nrm, fx, fy, room, tint: colour(0xC9CCCF) * (1 + 0.06 * streak), rough: 0.18, reach: 0.55) * (1 - 0.5 * sh)
        case 3:
            col = metal(nrm, fx, fy, room, tint: colour(0xE2B55C), rough: 0.26, reach: 0.6) * (1 - 0.45 * sh)
        case 4:
            col = lacquer(nrm, fx, fy, room, shade: sh, base: colour(0x0C0A08))
        case 5:
            col = colour(0x060706) * (0.6 + 0.4 * (1 - sh))
        default:
            col = metal(nrm, fx, fy, room, tint: colour(0x3B3E3C), rough: 0.72, reach: 0.4) * (1 - 0.55 * sh)
        }
        out = mix(out, col * occl, cover.v[i])
        return (out, 1)
    }
}

// MARK: Heisoku: 閉塞器, the block instrument

// On the shelf above the lever frame sits the block instrument: one needle per
// line, saying whether a section is clear, has a train in it, or is blocked.
// It is Sekisho's record control. Here the needle stands on LINE CLEAR (green),
// in a polished mahogany case behind glass, as the app shows it while recording.

func renderHeisoku(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (0.04, 0.03, 0.6, 0.5), detail: d)
    let cx: Float = 512, cy: Float = 500, outer: Float = 352, inner: Float = 296
    let needleAngle: Float = -42
    let pores = d == .full ? fbm(n, cell: 1.4 * u, octaves: 2, seed: 33) : Field(n)
    let figure = fbm(n, cell: 120 * u, octaves: 3, seed: 35)
    var h = Field(n), part = [UInt8](repeating: 0, count: n * n), grain = Field(n), ink = [UInt8](repeating: 0, count: n * n)
    // parts: 0 mahogany, 1 brass bezel, 2 enamel face, 3 needle, 4 brass hub, 5 brass screw
    // ink on the face: 0 none, 1 green, 2 red, 3 amber, 4 black
    let screws: [(Float, Float, Float)] = [(206, 206, 0.6), (818, 206, 2.1), (206, 818, 1.2), (818, 818, 2.7)]
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
            // Quarter-sawn mahogany: straight stripes that wander and flash.
            let w = X + 22 * vnoise(Y / 170, X / 120, 31) + (d == .full ? 5 * vnoise(Y / 30, X / 24, 32) : 0)
            let stripe = sin(w / (d == .glyph ? 30 : 11)) * 0.5 + 0.5
            grain.v[i] = clamp01(stripe * 0.7 + 0.3 * (figure.v[i] * 0.5 + 0.5))
            var height = pores.v[i] * 0.25 - (d == .full ? 0.3 * stripe : 0), p: UInt8 = 0
            let dx = X - cx, dy = Y - cy, r = (dx * dx + dy * dy).squareRoot()
            if r < outer {
                if r > inner {
                    // The bezel: a rolled brass ring with a step down to the glass.
                    let q = (r - (inner + outer) / 2) / ((outer - inner) / 2)
                    height = 30 + 26 * (1 - q * q).squareRoot() + (r < inner + 10 ? -6 * (1 - (r - inner) / 10) : 0)
                    p = 1
                } else {
                    height = 16; p = 2
                    let b = bearing(dx, dy)
                    if d >= .mark || r > 150 {
                        if r > 160 && r < 252 {
                            if b > -64 && b < -20 { ink[i] = 1 } else if b > -12 && b < 12 { ink[i] = 2 } else if b > 20 && b < 64 { ink[i] = 3 }
                        }
                        if d >= .mark && (abs(r - 262) < 2.2 || abs(r - 154) < 1.6) && abs(b) < 70 { ink[i] = 4 }
                        for tick: Float in [-42, 0, 42] where d >= .mark {
                            if abs(b - tick) * .pi / 180 * r < 2.6 && r > 252 && r < 282 { ink[i] = 4 }
                        }
                    }
                    // The needle on LINE CLEAR, its counterweight behind the pivot.
                    let a = needleAngle * .pi / 180
                    let along = dx * sin(a) - dy * cos(a), side = dx * cos(a) + dy * sin(a)
                    let half: Float = along > 0 ? max(1.6, 10 * (1 - along / 246)) : 6
                    if along > -64 && along < 246 && abs(side) < half {
                        height = 34 + 4 * (1 - pow(abs(side) / half, 2)); p = 3
                    }
                    let tail = ((along + 62) * (along + 62) + side * side).squareRoot()
                    if tail < 22 { height = 34 + 5 * (1 - (tail / 22) * (tail / 22)).squareRoot(); p = 3 }
                    if r < 32 { height = 38 + 16 * (1 - (r / 32) * (r / 32)).squareRoot(); p = 4 }
                }
            }
            for (sx, sy, turn) in screws where d >= .mark {
                let ex = X - sx, ey = Y - sy, sr = (ex * ex + ey * ey).squareRoot()
                if sr < 19 {
                    var z = 5 + 9 * (1 - (sr / 19) * (sr / 19)).squareRoot()
                    if abs(ex * sin(turn) - ey * cos(turn)) < 2.6 && sr < 15 { z -= 5 }
                    height = z; p = 5
                }
            }
            part[i] = p
            h.v[i] = height * u
        }
    }
    let shadow = blur(softShadow(h, steps: 40, stride: 3.6 * u, soft: 1.4 * u, spread: 0.05), 1.2 * u)
    let near = blur(h, 4 * u), wide = blur(h, 18 * u)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let sh = shadow.v[i], occl = occlusion(h, near, wide, i, u)
        let falloff = 1.05 - 0.12 * (fx * 0.45 + fy * 0.55)
        let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
        let r = ((X - cx) * (X - cx) + (Y - cy) * (Y - cy)).squareRoot()
        switch part[i] {
        case 1:
            return (metal(nrm, fx, fy, room, tint: colour(0xDDAF57), rough: 0.2, reach: 0.65) * (1 - 0.45 * sh) * occl, 1)
        case 4, 5:
            return (metal(nrm, fx, fy, room, tint: colour(0xD9AA55), rough: 0.3, reach: 0.6) * (1 - 0.45 * sh) * occl, 1)
        case 2, 3:
            // Vitreous enamel, then the printed sectors, the black needle, and the glass over all of it.
            var base = colour(0xF2ECDF)
            switch ink[i] {
            case 1: base = colour(0x1E8A5A)
            case 2: base = colour(0xC8352B)
            case 3: base = colour(0xE2A400)
            case 4: base = colour(0x1A1816)
            default: break
            }
            let lit = clamp01(nrm.dot(light))
            var col: V3
            if part[i] == 3 {
                col = lacquer(nrm, fx, fy, room, shade: sh, base: colour(0x111111))
            } else {
                col = base * ((0.62 + 0.42 * lit) * (1 - 0.55 * sh))
            }
            // Under glass: a little darker at the rim, the window lying across the top left.
            let rim = smoothstep(inner - 40, inner, r)
            col = col * (1 - 0.18 * rim) * occl
            col = col + mix(room.sharp(fx, fy), room.soft(fx, fy), 0.6) * 0.06 + white * (0.04 * rim)
            return (col, 1)
        default:
            let base = mix(colour(0x3A140B), colour(0x7C3420), grain.v[i]) * (1 + 0.08 * pores.v[i])
            return (lacquer(nrm, fx, fy, room, shade: sh, base: base) * falloff * occl, 1)
        }
    }
}

// MARK: Shingō: 信号機, the colour-light signal

// The signal is what a lever moves. At night, against its black board with the
// white border, one lamp shows: green, proceed. Yellow and red stay dark, hooded
// against the sun. It is the status column of the app, at full size.

func renderShingo(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (0.04, 0.03, 0.6, 0.5), detail: d, night: true)
    let lampY: [Float] = [262, 512, 762], lensR: Float = 92
    let paint = fbm(n, cell: 26 * u, octaves: 3, seed: 51)
    let haze = fbm(n, cell: 160 * u, octaves: 3, seed: 53)
    var h = Field(n), part = [UInt8](repeating: 0, count: n * n), which = [UInt8](repeating: 0, count: n * n)
    // parts: 0 night, 1 white border, 2 black board, 3 lamp housing, 4 lens, 5 hood
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
            var height: Float = 0, p: UInt8 = 0
            let board = sdBox(X - 512, Y - 512, 196, 394, 196)
            if board < 0 {
                height = 40 + 5 * slab(board, 7) + paint.v[i] * 0.3
                p = -board < (d == .glyph ? 36 : 24) ? 1 : 2
            }
            for (k, ly) in lampY.enumerated() {
                let dx = X - 512, dy = Y - ly, r = (dx * dx + dy * dy).squareRoot()
                if r < 120 {
                    if r < lensR {
                        let q = r / lensR
                        // A stepped Fresnel lens behind a clear dome: rings you can see from 128 px.
                        let rings: Float = d >= .mark ? 0.9 * (r / 9 - (r / 9).rounded(.down)) : 0
                        height = 52 + 14 * (1 - q * q).squareRoot() + rings
                        p = 4; which[i] = UInt8(k)
                    } else if r < 118 {
                        let q = (r - 105) / 13
                        height = 46 + 18 * (1 - q * q).squareRoot(); p = 3
                    }
                }
                // The hood: a tube over the lens, deepest at the top, open below.
                let fromTop = abs(bearing(dx, dy))
                if r > 108 && r < 126 && fromTop < 104 {
                    let reach = smoothstep(104, 40, fromTop)
                    let z = 46 + 88 * reach + 6 * (1 - abs(r - 117) / 9)
                    if z > height { height = z; p = 5 }
                }
            }
            part[i] = p
            h.v[i] = height * u
        }
    }
    let shadow = blur(softShadow(h, steps: 44, stride: 4 * u, soft: 1.6 * u, spread: 0.06), 1.4 * u)
    let near = blur(h, 4 * u), wide = blur(h, 18 * u)
    let green = colour(0x2BE07F)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let sh = shadow.v[i], occl = occlusion(h, near, wide, i, u)
        let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
        let gx = X - 512, gy = Y - lampY[0], gr = (gx * gx + gy * gy).squareRoot()
        // The green lamp lights everything near it.
        let spill = green * (0.9 * exp(-max(0, gr - lensR) / 46) + 0.18 * exp(-gr / 240))
        switch part[i] {
        case 0:
            let sky = mix(d == .glyph ? colour(0x22407A) : colour(0x14244A), colour(0x050A18), smoothstep(0, 1, fy * 0.9 + 0.1 * haze.v[i]))
            return (sky * (1 + 0.12 * haze.v[i]) + green * (0.16 * exp(-gr / 300)), 1)
        case 1:
            let lit = clamp01(nrm.dot(light))
            let col = colour(0xE7E3DA) * (((d == .glyph ? 0.34 : 0.14) + 0.2 * lit) * (1 - 0.4 * sh) * (1 + 0.05 * paint.v[i])) + spill * 0.55
            return (col * occl, 1)
        case 2, 3, 5:
            let base = part[i] == 2 ? colour(0x0F1011) : colour(0x17181A)
            var col = lacquer(nrm, fx, fy, room, shade: sh, base: base) * 0.55
            col = col + spill * (part[i] == 5 ? 0.42 : 0.22) * clamp01(0.3 + nrm.z)
            return (col * occl, 1)
        default:
            let k = Int(which[i])
            let dx = X - 512, dy = Y - lampY[k], r = (dx * dx + dy * dy).squareRoot(), q = r / lensR
            if k == 0 {
                // Lit: a bright core, the Fresnel rings catching it, the hood's shadow cooling the top.
                let ringGlint: Float = d >= .mark ? pow(1 - abs(2 * (r / 9 - (r / 9).rounded(.down)) - 1), 6) : 0
                let core = mix(colour(0xD9FFE9) * 2.2, green * 1.25, smoothstep(0, 0.85, q))
                let col = core * (1 - 0.35 * sh) + green * (0.35 * ringGlint) + white * (0.25 * pow(max(0, nrm.dot(halfway)), 120))
                return (col, 1)
            }
            // Dark: tinted glass that only reflects.
            let tint = k == 1 ? colour(0xE0A21A) : colour(0xD02A1E)
            var col = lacquer(nrm, fx, fy, room, shade: sh, base: tint * 0.14) * 0.9
            col = col + tint * (0.05 * (1 - q)) + spill * 0.08
            return (col * occl, 1)
        }
    }
}

// MARK: Tsūhyō: 通票, the single-line tablet

// On a single-track line only one train may be in a section, and the driver
// proves it by holding the tablet: a brass disc handed over at the signal box,
// its cut-out (circle, square, triangle, oval) different for each section.
// It is the railway's own tegata. Here a triangle tablet (第三種) lies on its
// leather pouch, engraved 関所 and 通票.

func sdTriangleUp(_ px: Float, _ py: Float, _ r: Float) -> Float {
    // Equilateral, pointing up in buffer space (y down), centroid at the origin, half side r.
    let k = Float(3).squareRoot()
    var x = abs(px) - r, y = -py + r / k
    if x + k * y > 0 { (x, y) = ((x - k * y) / 2, (-k * x - y) / 2) }
    x -= min(max(x, -2 * r), 0)
    return -(x * x + y * y).squareRoot() * (y < 0 ? -1 : 1)
}

func renderTsuhyo(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (0.04, 0.03, 0.6, 0.5), detail: d)
    let cx: Float = 512, cy: Float = 498, R: Float = 300
    let letters = d >= .mark ? glyphField(n, [("関", 470, 296, 74, 0), ("所", 554, 296, 74, 0),
                                             ("通", 470, 704, 74, 0), ("票", 554, 704, 74, 0)]) : Field(n)
    let crease = fbm(n, cell: 90 * u, octaves: 4, seed: 71)
    let tarnish = fbm(n, cell: 50 * u, octaves: 4, seed: 73)
    var h = Field(n), part = [UInt8](repeating: 0, count: n * n)
    var grainF = Field(n)
    // parts: 0 leather, 1 brass, 2 engraving, 3 stitch thread, 4 polished rim
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
            // Pebbled cowhide, creased by use.
            let pb = d == .full ? pebble(X, Y, cell: 6.5, seed: 75) : (bump: Float(0), tone: Float(0))
            grainF.v[i] = pb.tone
            var height = 1.2 * pb.bump + 4 * crease.v[i], p: UInt8 = 0
            // The pouch seam: a groove and a row of slanted saddle stitches.
            let hw: Float = 352, hr: Float = 150
            let sd = sdBox(X - 512, Y - 512, hw, hw, hr)
            if d >= .mark && abs(sd) < 9 {
                height -= 2.5 * (1 - abs(sd) / 9)
                let qx = abs(X - 512), qy = abs(Y - 512)
                var param: Float
                if qx <= hw - hr { param = X } else if qy <= hw - hr { param = Y + 2000 }
                else { param = 4000 + atan2(qy - (hw - hr), qx - (hw - hr)) * hr }
                let ph = (param + sd * 0.7) / 24
                let f = ph - ph.rounded(.down)
                if f > 0.18 && f < 0.82 && abs(sd) < 4.5 {
                    height = height + 2.5 + 3 * bead(abs(f - 0.5) * 24, 8) * bead(abs(sd), 4.5); p = 3
                }
            }
            // The tablet: a brass disc with a rolled rim, minus its triangle.
            let dx = X - cx, dy = Y - cy, r = (dx * dx + dy * dy).squareRoot()
            let tri = sdTriangleUp(dx, dy - 22, 118) - 10
            let sdT = max(r - R, -tri)
            if sdT < 0 {
                var z = 6 + 26 * slab(sdT, 9)
                var pp: UInt8 = 1
                if r > R - 34 { z += 5 * bead(abs(r - (R - 18)), 16); pp = 4 }
                if d >= .mark && abs(r - (R - 46)) < 2 { z -= 1.6 }
                if letters.v[i] > 0.4 { z -= 2.4 * letters.v[i]; pp = 2 }
                height = z; p = pp
            }
            part[i] = p
            h.v[i] = height * u
        }
    }
    let shadow = blur(softShadow(h, steps: 40, stride: 3.6 * u, soft: 1.4 * u, spread: 0.06), 1.3 * u)
    let near = blur(h, 4 * u), wide = blur(h, 18 * u)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let lit = clamp01(nrm.dot(light)), sh = shadow.v[i], occl = occlusion(h, near, wide, i, u)
        let falloff = 1.06 - 0.16 * (fx * 0.45 + fy * 0.55)
        switch part[i] {
        case 1, 4:
            // Turned brass: fine concentric tool marks bend the reflection round the disc.
            let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
            let dx = X - cx, dy = Y - cy, r = max(1, (dx * dx + dy * dy).squareRoot())
            let turn = d == .full ? vnoise(r / 1.1, bearing(dx, dy) / 40, 77) : 0
            var nrm = nrm
            nrm = V3(x: nrm.x + 0.06 * turn * dx / r, y: nrm.y + 0.06 * turn * dy / r, z: nrm.z).normalised
            let t = clamp01(0.5 + 0.8 * tarnish.v[i])
            let tint = mix(colour(0xE6B862), colour(0xA9803E), part[i] == 4 ? t * 0.25 : t * 0.7)
            let col = metal(nrm, fx, fy, room, tint: tint, rough: part[i] == 4 ? 0.2 : 0.55, reach: 0.6)
            return (col * (1 - 0.5 * sh) * occl, 1)
        case 2:
            return (colour(0x2A1C0E) * ((0.5 + 0.5 * lit) * (1 - 0.5 * sh)) * occl, 1)
        case 3:
            let col = colour(0xE9DDBF) * ((0.42 + 0.7 * lit) * (1 - 0.55 * sh))
            return (col * occl * falloff, 1)
        default:
            // Oak-tanned, darker toward the edges where hands have burnished it.
            let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
            let edge = smoothstep(-40, 30, sdBox(X - 512, Y - 512, 352, 352, 150))
            var base = mix(colour(0x6E3B1F), colour(0x8A4F2A), clamp01(0.5 + 0.6 * crease.v[i]))
            base = base * (1 + 0.07 * grainF.v[i]) * (1 - 0.35 * edge)
            let nh = max(0, nrm.dot(halfway))
            let col = base * ((0.42 + 0.72 * lit) * (1 - 0.62 * sh) * occl) + white * (0.06 * pow(nh, 24) * (1 - sh))
            return (col * falloff, 1)
        }
    }
}

// MARK: Tegata: 手形, the traveller's pass

// The literal reading, kept to one option: the pass you showed at the
// checkpoint. A hinoki tablet, 通 (pass through) in sumi, the checkpoint's 改
// seal (inspected) in vermilion paste, hung on a green silk cord.

func renderTegata(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (0.04, 0.03, 0.6, 0.5), detail: d)
    let bx: Float = 512, by: Float = 534, bw: Float = 196, bh: Float = 360
    let sealCX: Float = 512, sealCY: Float = 770, sealTurn: Float = 0.045
    let inkRaw = glyphField(n, [("通", 512, 448, d == .glyph ? 400 : 350, 0)])
    let ink = blur(inkRaw, (d == .full ? 1.2 : 0.6) * u)
    let sealChar = d >= .mark ? glyphField(n, [("改", sealCX, sealCY, 118, sealTurn)]) : Field(n)
    let blot = fbm(n, cell: 5 * u, octaves: 3, seed: 81)
    let slub = fbm(n, cell: 40 * u, octaves: 3, seed: 83)
    let pores = d == .full ? fbm(n, cell: 1.3 * u, octaves: 2, seed: 85) : Field(n)
    var base = Field(n), part = [UInt8](repeating: 0, count: n * n), grainF = Field(n)
    // parts: 0 cloth, 1 hinoki, 2 ink, 3 seal paste, 4 hole
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
            // Indigo hemp: warp over weft, over and under.
            var height: Float = 0, p: UInt8 = 0
            if d >= .mark {
                let s: Float = 8
                let cxI = Int((X / s).rounded(.down)), cyI = Int((Y / s).rounded(.down))
                let warp = abs(sin(.pi * X / s)), weft = abs(sin(.pi * Y / s))
                height = ((cxI + cyI) & 1 == 0 ? warp : weft) * 2.2 + 0.8 * slub.v[i]
            }
            // The tablet, with a bevelled edge.
            let sd = sdBox(X - bx, Y - by, bw, bh, 26)
            if sd < 0 {
                let w = X + 30 * vnoise(Y / 300, X / 80, 41) + (d == .full ? 7 * vnoise(Y / 50, X / 18, 42) : 0)
                let ring = sin(w / (d == .glyph ? 16 : 6.5)) * 0.5 + 0.5
                grainF.v[i] = ring
                height = 34 * slab(sd, 8) + (d == .full ? 0.35 * ring + 0.2 * pores.v[i] : 0)
                p = 1
                // Ink sinks a little into the grain: denser on the late wood, feathered along it.
                let density = ink.v[i] * (d == .full ? 0.86 + 0.14 * ring + 0.1 * blot.v[i] : 1)
                if density > 0.5 { height += 0.5; p = 2 }
                // The seal: vermilion paste in a square, 改 left as bare wood, the edge broken by the grain.
                let rx = (X - sealCX) * cos(sealTurn) + (Y - sealCY) * sin(sealTurn)
                let ry = -(X - sealCX) * sin(sealTurn) + (Y - sealCY) * cos(sealTurn)
                let sq = sdBox(rx, ry, 80, 80, 5)
                let speck = d == .full ? blot.v[i] + 0.35 * (ring - 0.5) : 0
                if sq < 0 && sealChar.v[i] < 0.5 && speck > -0.55 {
                    // A frame line, then the field: 白文, the character cut out of the red.
                    p = 3; height += 0.4
                }
                if d >= .mark && sq < -9 && sq > -15 { p = 1 }
            }
            let hr = ((X - bx) * (X - bx) + (Y - 216) * (Y - 216)).squareRoot()
            if hr < 20 { height = -4; p = 4 }
            part[i] = p
            base.v[i] = height * u
        }
    }
    // The cord: through the hole and up out of the frame, two strands of green silk.
    var cords = Cords(ground: base, u: u)
    let half: Float = d == .glyph ? 15 : 11
    for side: Float in [-1, 1] {
        let path = bezier([(bx + side * 10, 214), (bx + side * 34, 150), (bx + side * 58, 90), (bx + side * 72, -10)], steps: 60)
        cords.lay(path, half: half, lift: { s in 4 + 60 * s }, seed: Int(side + 2))
    }
    let h = cords.height
    let shadow = blur(softShadow(h, steps: 40, stride: 3.6 * u, soft: 1.4 * u, spread: 0.06), 1.2 * u)
    let near = blur(h, 4 * u), wide = blur(h, 18 * u)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let lit = clamp01(nrm.dot(light)), sh = shadow.v[i], occl = occlusion(h, near, wide, i, u)
        let nh = max(0, nrm.dot(halfway))
        let falloff = 1.06 - 0.16 * (fx * 0.45 + fy * 0.55)
        var out: V3
        switch part[i] {
        case 1:
            let wood = mix(colour(0xEBD6AE), colour(0xD3AF78), grainF.v[i]) * (1 + 0.05 * pores.v[i])
            out = wood * ((0.55 + 0.52 * lit) * (1 - 0.55 * sh) * occl) + white * (0.05 * pow(nh, 30) * (1 - sh))
        case 2:
            out = lacquer(nrm, fx, fy, room, shade: sh, base: colour(0x161211)) * occl
        case 3:
            out = colour(0xC93A2A) * ((0.5 + 0.5 * lit) * (1 - 0.5 * sh) * (1 + 0.06 * blot.v[i])) * occl
        case 4:
            out = colour(0x0B0D14)
        default:
            let indigo = mix(colour(0x1A2A4D), colour(0x2A4170), clamp01(0.5 + 0.7 * slub.v[i]))
            out = indigo * ((0.48 + 0.6 * lit) * (1 - 0.65 * sh) * occl) * falloff
        }
        let m = cords.mask.v[i]
        if m > 0 {
            let tone = clamp01(0.3 + 0.45 * cords.ply.v[i] + 0.25 * cords.fibre.v[i])
            let silk = mix(colour(0x0F4A30), colour(0x3DB27A), tone)
            let col = silk * ((0.3 + 0.8 * lit) * (1 - 0.6 * sh) * occl) + white * (0.16 * pow(nh, 22) * (1 - sh))
            out = mix(out, col, m)
        }
        return (out, 1)
    }
}

// MARK: Variants

struct Variant {
    let id: String, name: String, kanji: String, line: String
    let render: (Detail, Int) -> CGImage
    var story = ""
    var swatches: [(String, UInt32)] = []
}

let variants = [
    Variant(id: "teko", name: "Teko", kanji: "梃子", line: "The lever that holds or clears", render: renderTeko,
            story: """
            In a signal box every signal is worked by a lever in one long frame:
            pull it and the signal clears, leave it and it holds. Sekisho's tools
            are levers in its interface, so the lever is the product. Red enamel
            worn to the iron where boots catch it, a steel handle bright from the
            signalman's cloth, the spring catch, and the brass plate with its number.
            """,
            swatches: [("lever red", 0xB52B22), ("frame green", 0x1D4636), ("brass", 0xE2B55C), ("steel", 0xC9CCCF)]),
    Variant(id: "heisoku", name: "Heisoku", kanji: "閉塞器", line: "The block instrument on LINE CLEAR", render: renderHeisoku,
            story: """
            On the shelf above the frame, the block instrument says whether a
            section is clear, occupied or blocked. It is Sekisho's record control.
            The needle stands on green, line clear, over vitreous enamel, behind
            glass, in a brass bezel set into polished mahogany.
            """,
            swatches: [("proceed", 0x1E8A5A), ("mahogany", 0x7C3420), ("enamel", 0xF2ECDF), ("brass", 0xDDAF57)]),
    Variant(id: "shingo", name: "Shingō", kanji: "信号機", line: "The signal at night, showing green", render: renderShingo,
            story: """
            The signal is what a lever moves. At night, on its black board with
            the white border, one lamp shows: green, proceed. Yellow and red stay
            dark under their hoods. The status column of the app, at full size.
            """,
            swatches: [("proceed", 0x2BE07F), ("board", 0x0F1011), ("border", 0xE7E3DA), ("night", 0x14244A)]),
    Variant(id: "tsuhyo", name: "Tsūhyō", kanji: "通票", line: "The tablet a driver must hold", render: renderTsuhyo,
            story: """
            On a single line only one train may enter a section, and the driver
            proves it by holding the tablet handed over at the signal box: a
            brass disc whose cut-out differs per section. The railway's own
            checkpoint pass. A triangle tablet on its pouch, engraved 関所 通票.
            """,
            swatches: [("brass", 0xE6B862), ("leather", 0x7A4424), ("thread", 0xE9DDBF), ("patina", 0x2A1C0E)]),
    Variant(id: "tegata", name: "Tegata", kanji: "手形", line: "The traveller's pass, sealed 改", render: renderTegata,
            story: """
            The pass a traveller showed at the checkpoint: a hinoki tablet with
            通, pass through, in sumi, and the checkpoint's seal, 改, inspected,
            in vermilion paste. It hangs on a green silk cord, Sekisho's colour,
            on indigo hemp.
            """,
            swatches: [("hinoki", 0xE3C894), ("sumi", 0x161211), ("seal", 0xC93A2A), ("silk", 0x3DB27A)]),
]

/// Rendered at twice the slot size (at least 256) and scaled down, so small
/// sizes are smooth; the detail follows the slot, not the render.
func renderSize(_ size: CGFloat) -> Int { min(2048, max(256, Int(size) * 2)) }

/// The tile with the macOS drop shadow, filled edge to edge with the scene.
func drawIcon(_ ctx: CGContext, size: CGFloat, variant: Variant) {
    let image = variant.render(Detail(pixels: size), renderSize(size))
    let k = size / 1024
    ctx.saveGState()
    ctx.scaleBy(x: k, y: k)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(tile)
    ctx.setFillColor(sumi)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()
}

// MARK: Bitmaps

func bitmap(width: Int, height: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: Brand sheets and lockups

func text(_ string: String, font: NSFont, color: CGColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: kern])
}

func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
func mincho(_ size: CGFloat) -> NSFont { NSFont(name: "HiraMinProN-W6", size: size) ?? sans(size, .semibold) }

/// Each size drawn natively, as the icon set ships it, so the sheet shows what the Dock shows.
func drawSizes(_ ctx: CGContext, variant: Variant, sizes: [CGFloat], x: CGFloat, y: CGFloat, gap: CGFloat, label: CGColor?) {
    var x = x
    let tallest = sizes.max() ?? 0
    for size in sizes {
        let icon = bitmap(width: Int(size), height: Int(size)) { drawIcon($0, size: size, variant: variant) }
        ctx.draw(icon.cgImage!, in: CGRect(x: x, y: y + (tallest - size) / 2, width: size, height: size))
        if let label {
            let t = text("\(Int(size))", font: mono(16), color: label)
            t.draw(at: CGPoint(x: x + (size - t.size().width) / 2, y: y - 34))
        }
        x += size + gap
    }
}

func drawSheet(_ ctx: CGContext, width: CGFloat, height: CGFloat, hero: Variant) {
    ctx.setFillColor(surface)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let side: CGFloat = 1120
    ctx.saveGState()
    ctx.translateBy(x: 80, y: (height - side) / 2)
    ctx.scaleBy(x: side / 1024, y: side / 1024)
    drawIcon(ctx, size: 1024, variant: hero)
    ctx.restoreGState()

    let left: CGFloat = 1300
    text("Sekisho", font: sans(132, .semibold), color: sumi, kern: -2).draw(at: CGPoint(x: left, y: 1150))
    text("\(hero.kanji)  ·  \(hero.name)  ·  関所", font: mincho(46), color: proceedCG, kern: 5).draw(at: CGPoint(x: left + 6, y: 1078))
    let para = NSMutableParagraphStyle()
    para.lineSpacing = 10
    NSAttributedString(string: hero.story, attributes: [.font: sans(28), .foregroundColor: NSColor(cgColor: sumi.copy(alpha: 0.72)!)!,
                                                        .paragraphStyle: para])
        .draw(in: CGRect(x: left, y: 800, width: 1020, height: 262))

    for (i, s) in hero.swatches.enumerated() {
        let x = left + CGFloat(i) * 250, y: CGFloat = 728
        ctx.setFillColor(rgb(s.1))
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: 44, height: 44))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: x, y: y, width: 44, height: 44))
        text(s.0, font: sans(20, .medium), color: sumi).draw(at: CGPoint(x: x + 58, y: y + 22))
        text(String(format: "#%06X", s.1), font: mono(17), color: sumi.copy(alpha: 0.55)!).draw(at: CGPoint(x: x + 58, y: y))
    }

    for row in 0..<2 {
        let y: CGFloat = row == 0 ? 430 : 100
        let strip = CGRect(x: left - 30, y: y - 50, width: 1020, height: 320)
        ctx.addPath(CGPath(roundedRect: strip, cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.setFillColor(row == 0 ? paper : sumi)
        ctx.fillPath()
        drawSizes(ctx, variant: hero, sizes: [256, 128, 64, 32, 16], x: left, y: y, gap: 56,
                  label: (row == 0 ? sumi : paper).copy(alpha: 0.5)!)
    }
}

/// The showreel: all five side by side, each with its Dock sizes on light and dark.
func drawAlternates(_ ctx: CGContext, width: CGFloat, height: CGFloat, chosen: String) {
    ctx.setFillColor(surface)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    text("Sekisho  ·  関所", font: sans(56, .semibold), color: sumi, kern: -0.5).draw(at: CGPoint(x: 90, y: height - 130))
    text("Five objects from the checkpoint and the signal box. Same renderer, same window as Kagami and Kekkai.",
         font: sans(24), color: sumi.copy(alpha: 0.6)!).draw(at: CGPoint(x: 92, y: height - 178))
    let column = (width - 180) / CGFloat(variants.count)
    for (i, v) in variants.enumerated() {
        let x0 = 90 + CGFloat(i) * column, iconSide = column - 60
        ctx.saveGState()
        ctx.translateBy(x: x0, y: height - 250 - iconSide)
        ctx.scaleBy(x: iconSide / 1024, y: iconSide / 1024)
        drawIcon(ctx, size: 1024, variant: v)
        ctx.restoreGState()
        let top = height - 270 - iconSide
        let isChosen = v.id == chosen
        text(v.name + (isChosen ? "  ·  in the app" : ""), font: sans(30, .semibold), color: isChosen ? proceedCG : sumi)
            .draw(at: CGPoint(x: x0 + 20, y: top - 40))
        text(v.kanji, font: mincho(24), color: sumi.copy(alpha: 0.7)!, kern: 3).draw(at: CGPoint(x: x0 + 20, y: top - 78))
        text(v.line, font: sans(19), color: sumi.copy(alpha: 0.6)!).draw(at: CGPoint(x: x0 + 20, y: top - 110))
        for row in 0..<2 {
            let y = top - 300 - CGFloat(row) * 170
            let strip = CGRect(x: x0 + 10, y: y - 20, width: iconSide - 20, height: 150)
            ctx.addPath(CGPath(roundedRect: strip, cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.setFillColor(row == 0 ? paper : sumi)
            ctx.fillPath()
            drawSizes(ctx, variant: v, sizes: [110, 64, 32, 16], x: x0 + 30, y: y, gap: 22, label: nil)
        }
    }
}

// MARK: Main

let args = Array(CommandLine.arguments.dropFirst())
guard let outPath = args.first, !outPath.hasPrefix("--") else {
    print("usage: make-icon <AppIcon.iconset|AppIcon.appiconset> [--variant \(variants.map(\.id).joined(separator: "|"))] [--brand <folder>] [--preview <folder>]")
    exit(1)
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// The leather for the app's sidebar: the tablet's pouch, one panel larger than any sidebar (scaled to fill,
// so there is no seam to tile). Same window and same pebbled cowhide as the icon, without the stitching:
// the app draws its seam itself. Written as JPEG; it has no alpha and the PNG would be ten times the size.
if let texturePath = option("--texture") {
    let w = 840, hgt = 3600
    func leatherHeight(_ X: Float, _ Y: Float) -> Float {
        var crease: Float = 0, amp: Float = 1, cell: Float = 180
        for o in 0..<4 { crease += amp * vnoise(X / cell, Y / cell, 171 + o * 13); amp *= 0.5; cell /= 2 }
        return 0.6 * pebble(X, Y, cell: 4.6, seed: 175).bump + 9 * crease
    }
    var rgba = [UInt8](repeating: 255, count: w * hgt * 4)
    for y in 0..<hgt {
        for x in 0..<w {
            let X = Float(x), Y = Float(y)
            let h0 = leatherHeight(X, Y)
            let nrm = V3(x: -(leatherHeight(X + 1, Y) - h0), y: -(leatherHeight(X, Y + 1) - h0), z: 1).normalised
            let lit = clamp01(nrm.dot(light)), nh = max(0, nrm.dot(halfway))
            let hue = clamp01(0.5 + 0.55 * vnoise(X / 260, Y / 260, 181) + 0.1 * pebble(X, Y, cell: 4.6, seed: 175).tone)
            let base = mix(colour(0x4A2817), colour(0x744023), hue)
            let c = base * (0.5 + 0.62 * lit) + white * (0.05 * pow(nh, 22))
            let i = (y * w + x) * 4
            rgba[i] = UInt8(tone(c.x) * 255); rgba[i + 1] = UInt8(tone(c.y) * 255); rgba[i + 2] = UInt8(tone(c.z) * 255)
        }
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: hgt, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    _ = rgba.withUnsafeBytes { memcpy(rep.bitmapData!, $0.baseAddress!, w * hgt * 4) }
    let dir = URL(fileURLWithPath: texturePath)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])!.write(to: dir.appendingPathComponent("leather.jpg"))
    print("Wrote \(dir.path)/leather.jpg")
    exit(0)
}

if let previewPath = option("--preview") {
    let dir = URL(fileURLWithPath: previewPath)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for v in variants where option("--only").map({ $0 == v.id }) ?? true {
        try write(bitmap(width: 512, height: 512) { drawIcon($0, size: 512, variant: v) }, to: dir.appendingPathComponent("\(v.id).png"))
        try write(bitmap(width: 400, height: 100) { ctx in
            for (k, s) in [64, 32, 16].enumerated() {
                ctx.setFillColor(k == 0 ? paper : paper)
                drawSizes(ctx, variant: v, sizes: [CGFloat(s)], x: CGFloat(20 + k * 110), y: 18, gap: 0, label: nil)
            }
        }, to: dir.appendingPathComponent("\(v.id)-small.png"))
    }
    print("Wrote previews to \(dir.path)")
    exit(0)
}

let chosenID = option("--variant") ?? "tsuhyo"
guard let chosen = variants.first(where: { $0.id == chosenID }) else {
    print("unknown variant \(chosenID); one of: \(variants.map(\.id).joined(separator: ", "))")
    exit(1)
}
let outDir = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

struct Slot { let size: Int; let scale: Int }
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(size: $0, scale: 1), Slot(size: $0, scale: 2)] }
var images: [[String: String]] = []
for slot in slots {
    let pixels = slot.size * slot.scale
    let name = "icon_\(slot.size)x\(slot.size)\(slot.scale == 2 ? "@2x" : "").png"
    try write(bitmap(width: pixels, height: pixels) { drawIcon($0, size: CGFloat(pixels), variant: chosen) },
              to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(slot.size)x\(slot.size)", "scale": "\(slot.scale)x", "filename": name])
}
if outDir.pathExtension == "appiconset" {
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: outDir.appendingPathComponent("Contents.json"))
}
print("Wrote \(slots.count) \(chosen.id) icon sizes to \(outDir.path)")

if let brandPath = option("--brand") {
    let brand = URL(fileURLWithPath: brandPath)
    try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
    for v in variants {
        try write(bitmap(width: 1024, height: 1024) { drawIcon($0, size: 1024, variant: v) },
                  to: brand.appendingPathComponent("sekisho-icon-\(v.id).png"))
        try write(bitmap(width: 2400, height: 1400) { drawSheet($0, width: 2400, height: 1400, hero: v) },
                  to: brand.appendingPathComponent("sekisho-sheet-\(v.id).png"))
    }
    try write(bitmap(width: 3300, height: 1460) { drawAlternates($0, width: 3300, height: 1460, chosen: chosen.id) },
              to: brand.appendingPathComponent("sekisho-options.png"))
    try write(bitmap(width: 1024, height: 1024) { drawIcon($0, size: 1024, variant: chosen) },
              to: brand.appendingPathComponent("sekisho-icon.png"))
    print("Wrote brand assets to \(brand.path)")
}
