// Renders a 20 s launch video (1920×1080, 30 fps) from real Portside renders with demo data.
//   ./build.sh && swift scripts/make-video.swift      → build/launch/portside-launch.mp4
// Needs ffmpeg. Every frame is drawn in code, so it's reproducible and never shows real projects.
import AppKit

let W = 1920, H = 1080, fps = 30.0, duration = 20.0
let out = URL(fileURLWithPath: "build/launch")
let app = "build/Portside.app/Contents/MacOS/Portside"

// MARK: - Popover states, rendered by the app itself

func run(_ path: String, _ args: [String], stdin: Pipe? = nil) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let stdin { p.standardInput = stdin }
    try! p.run()
    return p
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func state(_ name: String, _ flags: [String]) -> NSImage {
    let path = out.appendingPathComponent("\(name).png").path
    run(app, ["--snapshot", path, "--dark"] + flags).waitUntilExit()
    guard let image = NSImage(contentsOfFile: path) else { fatalError("Run ./build.sh first") }
    return image
}
let full = state("full", ["--demo"])
let hover = state("hover", ["--demo", "--hover", "103"])
let dropped = state("dropped", ["--demo", "--demo-drop", "103"])
let confirm = state("confirm", ["--demo", "--demo-drop", "103", "--confirm"])
let empty = state("empty", ["--demo-empty"])
let icon = NSImage(contentsOfFile: "Resources/AppIcon.png")!

/// Snapshots are 2× renders, so one image pixel is one video pixel.
func pixelSize(_ image: NSImage) -> CGSize {
    let rep = image.representations.first!
    return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
}

// MARK: - Timing helpers

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
func ease(_ x: Double) -> Double { let x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { ease((t - a) / (b - a)) }
func fade(_ t: Double, in a: Double, out b: Double, over d: Double = 0.3) -> Double {
    clamp((t - a) / d) * clamp((b - t) / d)
}
func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }

// MARK: - Layout

let menuBarHeight: CGFloat = 48
let itemCenterX: CGFloat = 1560
let popover = CGPoint(x: 1184, y: 60) // top-left, where macOS would place it under the item
func inPopover(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: popover.x + x, y: popover.y + y) }

struct Key { let t: Double; let p: CGPoint }
let cursorPath: [Key] = [
    Key(t: 0, p: CGPoint(x: 1000, y: 700)),
    Key(t: 2.1, p: CGPoint(x: 1000, y: 700)),
    Key(t: 3.2, p: CGPoint(x: itemCenterX, y: 26)),     // click the menu bar item
    Key(t: 3.9, p: CGPoint(x: itemCenterX, y: 26)),
    Key(t: 4.8, p: CGPoint(x: 1090, y: 470)),            // rest beside the popover
    Key(t: 7.2, p: CGPoint(x: 1090, y: 470)),
    Key(t: 8.1, p: inPopover(300, 470)),                 // hover the worktree's Next.js
    Key(t: 8.7, p: inPopover(300, 470)),
    Key(t: 9.3, p: inPopover(680, 465)),                 // its stop button
    Key(t: 10.3, p: inPopover(680, 465)),
    Key(t: 11.2, p: inPopover(74, 797)),                 // Stop All
    Key(t: 11.7, p: inPopover(74, 797)),
    Key(t: 12.3, p: inPopover(645, 797)),                // confirm
    Key(t: 13.2, p: inPopover(645, 797)),
    Key(t: 14.2, p: CGPoint(x: 1090, y: 620)),
    Key(t: 20, p: CGPoint(x: 1090, y: 620)),
]
let clicks: [Double] = [3.3, 9.45, 11.4, 12.4]

func cursor(at t: Double) -> CGPoint {
    for (a, b) in zip(cursorPath, cursorPath.dropFirst()) where t <= b.t {
        let p = progress(t, a.t, b.t)
        return CGPoint(x: mix(a.p.x, b.p.x, p), y: mix(a.p.y, b.p.y, p))
    }
    return cursorPath.last!.p
}

struct Caption { let start, end: Double; let title, sub: String }
let captions = [
    Caption(start: 0.1, end: 3.1, title: "Which node is on :3000?", sub: "Too many dev servers. No idea which is which."),
    Caption(start: 3.5, end: 7.1, title: "Every dev server\non your Mac.", sub: "Grouped by repo and git worktree."),
    Caption(start: 7.2, end: 8.9, title: "See who started it.", sub: "Claude Code, Codex, Cursor, your terminal…"),
    Caption(start: 9.0, end: 11.0, title: "Stop it in one click.", sub: "The whole npm → node chain. Never its neighbors."),
    Caption(start: 11.1, end: 13.4, title: "Or stop everything.", sub: "One confirm, done."),
    Caption(start: 13.5, end: 15.8, title: "Light enough to forget.", sub: "~1 ms scans · 17 MB · no network"),
]

// MARK: - Drawing

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func text(_ s: String, _ font: NSFont, _ c: NSColor, at p: CGPoint, alpha: CGFloat = 1, align: NSTextAlignment = .left, width: CGFloat = 1200) {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineSpacing = font.pointSize * 0.08
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c.withAlphaComponent(c.alphaComponent * alpha), .paragraphStyle: style]
    let x = align == .center ? p.x - width / 2 : align == .right ? p.x - width : p.x
    NSAttributedString(string: s, attributes: attrs).draw(with: NSRect(x: x, y: p.y, width: width, height: 400),
                                                          options: [.usesLineFragmentOrigin])
}

func wallpaper() {
    NSGradient(colors: [color(0x0E1226), color(0x1C1638), color(0x2A1B4A)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 60)
    for (center, radius, hex, a) in [(CGPoint(x: 1650, y: 250), 700.0, UInt32(0x3558D6), 0.35),
                                     (CGPoint(x: 250, y: 950), 800.0, UInt32(0x8A3FD1), 0.28)] {
        NSGradient(colors: [color(hex, a), color(hex, 0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
}

func symbol(_ name: String, size: CGFloat, at p: CGPoint, alpha: CGFloat = 0.9) {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    img.draw(in: NSRect(x: p.x, y: p.y - img.size.height / 2, width: img.size.width, height: img.size.height),
             from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
}

func menuBar(t: Double, open: Double) {
    color(0x000000, 0.28).setFill()
    NSRect(x: 0, y: 0, width: W, height: Int(menuBarHeight)).fill()
    let mid = menuBarHeight / 2
    text("Thu 9:41 AM", .systemFont(ofSize: 26, weight: .medium), .white, at: CGPoint(x: 1890, y: mid - 16), align: .right, width: 300)
    symbol("wifi", size: 24, at: CGPoint(x: 1690, y: mid))
    symbol("battery.75percent", size: 24, at: CGPoint(x: 1620, y: mid))

    // Portside's item: highlighted while its menu is open, count until everything's stopped.
    let count = t < 9.75 ? "8" : t < 12.5 ? "7" : ""
    let itemWidth: CGFloat = count.isEmpty ? 52 : 84
    if open > 0 {
        color(0xFFFFFF, 0.22 * open).setFill()
        NSBezierPath(roundedRect: NSRect(x: itemCenterX - itemWidth / 2, y: 6, width: itemWidth, height: 36), xRadius: 8, yRadius: 8).fill()
    }
    symbol("server.rack", size: 23, at: CGPoint(x: itemCenterX - itemWidth / 2 + 12, y: mid), alpha: 1)
    if !count.isEmpty {
        text(count, .systemFont(ofSize: 26, weight: .semibold), .white, at: CGPoint(x: itemCenterX + 10, y: mid - 16), width: 40)
    }
}

func terminal(alpha: Double, t: Double) {
    guard alpha > 0 else { return }
    let frame = NSRect(x: 1184, y: 200, width: 720, height: 400)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.5 * alpha)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    color(0x15161C, 0.96 * alpha).setFill()
    NSBezierPath(roundedRect: frame, xRadius: 20, yRadius: 20).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        color(hex, alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: frame.minX + 28 + CGFloat(i) * 34, y: frame.minY + 24, width: 22, height: 22)).fill()
    }
    let lines = ["$ lsof -iTCP -sTCP:LISTEN", "node  48213  you  TCP *:3000 (LISTEN)", "node  48227  you  TCP *:3001 (LISTEN)",
                 "node  48240  you  TCP *:3002 (LISTEN)", "node  48301  you  TCP *:5173 (LISTEN)", "python 48355 you  TCP *:8000 (LISTEN)",
                 "$ kill -9 …which one?"]
    let mono = NSFont.monospacedSystemFont(ofSize: 25, weight: .regular)
    for (i, line) in lines.enumerated() {
        let shown = clamp((t - 0.25 - Double(i) * 0.22) / 0.12)
        guard shown > 0 else { continue }
        let c = line.hasPrefix("$") ? color(0x7EE787) : color(0xC9D1D9)
        text(line, mono, c, at: CGPoint(x: frame.minX + 36, y: frame.minY + 78 + CGFloat(i) * 42), alpha: CGFloat(alpha * shown), width: 680)
    }
}

/// The popover: the current app render, crossfading (and resizing) between states.
func popoverView(t: Double) -> (NSImage, NSImage?, Double) {
    switch t {
    case ..<8.15: return (full, nil, 0)
    case ..<9.55: return (hover, nil, 0)
    case ..<9.95: return (hover, dropped, progress(t, 9.55, 9.95))
    case ..<11.45: return (dropped, nil, 0)
    case ..<12.45: return (confirm, nil, 0)
    case ..<12.9: return (confirm, empty, progress(t, 12.45, 12.9))
    default: return (empty, nil, 0)
    }
}

func drawPopover(t: Double, open: Double) {
    guard open > 0 else { return }
    let (a, b, p) = popoverView(t: t)
    let sa = pixelSize(a), sb = b.map(pixelSize) ?? sa
    let height = mix(sa.height, sb.height, p)
    let scale = mix(0.96, 1, open)
    let frame = NSRect(x: popover.x + sa.width * (1 - scale) / 2, y: popover.y, width: sa.width * scale, height: height * scale)
    let shape = NSBezierPath(roundedRect: frame, xRadius: 22, yRadius: 22)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.55 * open)
    shadow.shadowBlurRadius = 50
    shadow.shadowOffset = NSSize(width: 0, height: -20)
    shadow.set()
    color(0x1F1F1F, open).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    func draw(_ img: NSImage, _ alpha: Double) {
        let s = pixelSize(img)
        img.draw(in: NSRect(x: frame.minX, y: frame.minY, width: s.width * scale, height: s.height * scale),
                 from: .zero, operation: .sourceOver, fraction: CGFloat(alpha * open), respectFlipped: true, hints: nil)
    }
    draw(a, 1 - p)
    if let b { draw(b, p) }
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.12 * open).setStroke()
    shape.lineWidth = 2
    shape.stroke()
}

func drawCursor(at p: CGPoint, t: Double, alpha: Double) {
    guard alpha > 0 else { return }
    for c in clicks where t >= c && t < c + 0.35 {
        let k = (t - c) / 0.35
        color(0xFFFFFF, CGFloat(0.55 * (1 - k) * alpha)).setStroke()
        let r = CGFloat(10 + 34 * k)
        let ring = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = 4
        ring.stroke()
    }
    let pressed = clicks.contains { t >= $0 - 0.05 && t < $0 + 0.1 }
    let s: CGFloat = pressed ? 2.0 : 2.3
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4, 13.2), (7, 20), (9.4, 19), (6.5, 12.3), (12, 12.3)]
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: p.x + pts[0].0 * s, y: p.y + pts[0].1 * s))
    for pt in pts.dropFirst() { arrow.line(to: CGPoint(x: p.x + pt.0 * s, y: p.y + pt.1 * s)) }
    arrow.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.4 * alpha)
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = NSSize(width: 0, height: -3)
    shadow.set()
    color(0x000000, CGFloat(alpha)).setFill()
    arrow.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, CGFloat(alpha)).setStroke()
    arrow.lineWidth = 2.6
    arrow.lineJoinStyle = .round
    arrow.stroke()
}

func drawCaptions(t: Double) {
    for c in captions {
        let a = fade(t, in: c.start, out: c.end)
        guard a > 0 else { continue }
        let rise = CGFloat(1 - ease((t - c.start) / 0.4)) * 24
        let lines = CGFloat(c.title.split(separator: "\n").count)
        let top = 470 - lines * 44 + rise
        text(c.title, .systemFont(ofSize: 80, weight: .bold), .white, at: CGPoint(x: 140, y: top), alpha: CGFloat(a), width: 960)
        text(c.sub, .systemFont(ofSize: 36, weight: .regular), color(0xFFFFFF, 0.72),
             at: CGPoint(x: 142, y: top + lines * 96 + 20), alpha: CGFloat(a), width: 960)
    }
}

func endCard(t: Double) {
    let a = progress(t, 15.9, 16.5)
    guard a > 0 else { return }
    color(0x0B0D1A, CGFloat(0.9 * a)).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    let rise = CGFloat(1 - a) * 30
    let size: CGFloat = 240
    icon.draw(in: NSRect(x: CGFloat(W) / 2 - size / 2, y: 250 + rise, width: size, height: size),
              from: .zero, operation: .sourceOver, fraction: CGFloat(a), respectFlipped: true, hints: nil)
    let cx = CGFloat(W) / 2
    text("Portside", .systemFont(ofSize: 96, weight: .bold), .white, at: CGPoint(x: cx, y: 520 + rise), alpha: CGFloat(a), align: .center)
    text("Every dev server on your Mac, one click away.", .systemFont(ofSize: 38), color(0xFFFFFF, 0.75),
         at: CGPoint(x: cx, y: 650 + rise), alpha: CGFloat(a), align: .center)
    let b = progress(t, 16.5, 17.0)
    text("Free & open source  ·  github.com/guneysol/portside", .monospacedSystemFont(ofSize: 32, weight: .medium),
         color(0x7EB6FF), at: CGPoint(x: cx, y: 760), alpha: CGFloat(a * b), align: .center, width: 1400)
}

// MARK: - Render → ffmpeg

let video = out.appendingPathComponent("portside-launch.mp4").path
let pipe = Pipe()
let ffmpeg = run("/opt/homebrew/bin/ffmpeg", [
    "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(W)x\(H)", "-r", "\(Int(fps))", "-i", "-",
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-preset", "slow", "-movflags", "+faststart", video,
], stdin: pipe)

let bytesPerRow = W * 4
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(H))
ctx.scaleBy(x: 1, y: -1) // draw top-down
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

let frames = Int(duration * fps)
for i in 0..<frames {
    let t = Double(i) / fps
    let open = t < 3.35 ? 0 : t < 15.3 ? progress(t, 3.35, 3.6) : 1 - progress(t, 15.3, 15.6)
    wallpaper()
    // Camera: push in on the popover while rows are being stopped, so it reads on a phone.
    let zoom = 1 + 0.22 * (progress(t, 7.0, 7.8) - progress(t, 13.2, 14.0))
    NSGraphicsContext.saveGraphicsState()
    let camera = NSAffineTransform()
    camera.translateX(by: 1920, yBy: 100)
    camera.scale(by: zoom)
    camera.translateX(by: -1920, yBy: -100)
    camera.concat()
    terminal(alpha: 1 - progress(t, 2.7, 3.2), t: t)
    menuBar(t: t, open: open)
    drawPopover(t: t, open: open)
    drawCursor(at: cursor(at: t), t: t, alpha: clamp((t - 1.9) / 0.3) * (1 - progress(t, 15.4, 15.8)))
    NSGraphicsContext.restoreGraphicsState()
    drawCaptions(t: t)
    endCard(t: t)
    ctx.flush()
    pipe.fileHandleForWriting.write(Data(bytes: ctx.data!, count: bytesPerRow * H))
}
try pipe.fileHandleForWriting.close()
ffmpeg.waitUntilExit()
print("Wrote \(video)")
