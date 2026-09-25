// Renders the Portside app icon and builds Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
// Drawn by hand (not an SF Symbol — Apple's license doesn't allow those in app icons).
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.current = nil }

    // macOS icon grid: 824pt rounded square centered on a 1024 canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x151B2B).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x2C3A58), color(0x131A2A)])!.draw(in: shape, angle: -90)

    // Soft top sheen.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [.white.withAlphaComponent(0.10), .white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Three rack units, each with a status light: web (blue), database (orange), running (green).
    let lights: [UInt32] = [0x30D158, 0x0A84FF, 0xFF9F0A]
    let slabSize = NSSize(width: 580, height: 150), gap: CGFloat = 42
    let top = tile.midY + (slabSize.height * 3 + gap * 2) / 2
    for (i, light) in lights.enumerated() {
        let slab = NSRect(x: tile.midX - slabSize.width / 2, y: top - slabSize.height * CGFloat(i + 1) - gap * CGFloat(i),
                          width: slabSize.width, height: slabSize.height)
        let slabPath = NSBezierPath(roundedRect: slab, xRadius: 34, yRadius: 34)
        NSGradient(colors: [color(0x44557A), color(0x33415F)])!.draw(in: slabPath, angle: -90)
        color(0xFFFFFF, 0.12).setStroke()
        slabPath.lineWidth = 3
        slabPath.stroke()

        // Status light with a glow.
        let center = NSPoint(x: slab.minX + 82, y: slab.midY)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color(light, 0.9)
        glow.shadowBlurRadius = 30
        glow.set()
        color(light).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52)).fill()
        NSGraphicsContext.restoreGraphicsState()
        color(0xFFFFFF, 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 12, y: center.y + 2, width: 18, height: 14)).fill()

        // Vent slots.
        for v in 0..<4 {
            let slot = NSRect(x: slab.maxX - 88 - CGFloat(v) * 46, y: slab.midY - 30, width: 18, height: 60)
            color(0xFFFFFF, 0.18).setFill()
            NSBezierPath(roundedRect: slot, xRadius: 9, yRadius: 9).fill()
        }
    }
    return rep
}

let rep = render()
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: out, withIntermediateDirectories: true)

let master = iconset.appendingPathComponent("master.png")
try rep.representation(using: .png, properties: [:])!.write(to: master)
try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("AppIcon.png"))

func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        run("/usr/bin/sips", ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
try fm.removeItem(at: master)
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path])
print("Wrote \(out.path)/AppIcon.icns")
