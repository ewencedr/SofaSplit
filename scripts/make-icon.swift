// Draws the SofaSplit icon: a split-screen TV (player 1 blue, player 2 green, the colours the controllers light up
// in) with a sofa in front, on a macOS-style rounded square.
//
//   swift scripts/make-icon.swift            -> Resources/AppIcon.icns and docs/logo.png
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }

func fill(_ path: NSBezierPath, _ top: NSColor, _ bottom: NSColor) {
    NSGradient(starting: bottom, ending: top)!.draw(in: path, angle: 90)
}

/// Draws on a 1024 × 1024 canvas (origin bottom left), following Apple's icon grid: an 824 pt body, 100 pt margin.
func drawIcon() {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = rounded(body, 185)

    // Soft drop shadow under the body.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x1B2445).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background: deep evening blue, lighter towards the top like a dim living room.
    fill(shape, color(0x2C3A6B), color(0x121834))

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()

    // TV glow on the wall.
    let glow = NSGradient(colors: [color(0x6FA8FF, 0.35), color(0x6FA8FF, 0)])!
    glow.draw(fromCenter: NSPoint(x: 512, y: 600), radius: 0, toCenter: NSPoint(x: 512, y: 600), radius: 420, options: [])

    // The TV: dark bezel, screen split into two players.
    let tv = CGRect(x: 212, y: 430, width: 600, height: 370)
    color(0x0B0F1F).setFill()
    rounded(tv, 46).fill()
    let screen = tv.insetBy(dx: 24, dy: 24)
    let half = (screen.width - 14) / 2
    let left = CGRect(x: screen.minX, y: screen.minY, width: half, height: screen.height)
    let right = CGRect(x: screen.maxX - half, y: screen.minY, width: half, height: screen.height)
    fill(rounded(left, 26), color(0x5AA2FF), color(0x1F5FE0))
    fill(rounded(right, 26), color(0x5BEA9C), color(0x15A85A))

    // A little player in each half: a head and shoulders, facing the viewer.
    for (rect, shade) in [(left, color(0xFFFFFF, 0.9)), (right, color(0xFFFFFF, 0.9))] {
        shade.setFill()
        let cx = rect.midX
        NSBezierPath(ovalIn: CGRect(x: cx - 34, y: rect.minY + 120, width: 68, height: 68)).fill()
        rounded(CGRect(x: cx - 62, y: rect.minY + 40, width: 124, height: 86), 40).fill()
    }

    // TV stand.
    color(0x0B0F1F).setFill()
    rounded(CGRect(x: 472, y: 398, width: 80, height: 40), 10).fill()

    // The sofa, in front of the TV.
    let sofaTop = color(0xFFB36B), sofaBottom = color(0xE07A3A)
    fill(rounded(CGRect(x: 230, y: 250, width: 564, height: 170), 60), sofaTop, sofaBottom)          // backrest
    fill(rounded(CGRect(x: 180, y: 150, width: 150, height: 210), 62), color(0xFFC285), sofaBottom)  // left arm
    fill(rounded(CGRect(x: 694, y: 150, width: 150, height: 210), 62), color(0xFFC285), sofaBottom)  // right arm
    fill(rounded(CGRect(x: 290, y: 170, width: 444, height: 130), 40), color(0xFFBE7D), color(0xEA8A47))  // seat
    // Seam between the two seat cushions: one seat per player.
    color(0xC9662C, 0.8).setFill()
    rounded(CGRect(x: 507, y: 182, width: 10, height: 108), 5).fill()
    // Feet.
    color(0x6B3415).setFill()
    rounded(CGRect(x: 214, y: 118, width: 44, height: 40), 12).fill()
    rounded(CGRect(x: 766, y: 118, width: 44, height: 40), 12).fill()

    NSGraphicsContext.restoreGraphicsState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("SofaSplit.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try p.run()
p.waitUntilExit()
try png(size: 512).write(to: root.appendingPathComponent("docs/logo.png"))
print("Wrote \(icns.path) and docs/logo.png")
