// Renders the DMG window background: dark, a warm glow at the bottom like the
// site's hero, the instruction line up top and an arrow between where the app
// icon and the Applications shortcut sit (see settings.py for those positions).
//
//   swift render-background.swift            → background.png + background@2x.png
//
// The window is 660×400 pt. Icons are 128 pt at (160, 200) and (500, 200).
import AppKit

let size = NSSize(width: 660, height: 400)

func render(scale: CGFloat) -> Data {
    let px = NSSize(width: size.width * scale, height: size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let bounds = NSRect(origin: .zero, size: size)

    // Base
    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
    bounds.fill()

    // Warm glow rising from the bottom, matching the OG image
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.10, alpha: 0.55).cgColor,
                                   NSColor(calibratedRed: 0.55, green: 0.12, blue: 0.25, alpha: 0.18).cgColor,
                                   NSColor.clear.cgColor] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size.width / 2, y: -60), startRadius: 0,
                           endCenter: CGPoint(x: size.width / 2, y: -60), endRadius: 420, options: [])

    // Instruction
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let title = NSAttributedString(string: "Drag Better Emoji to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.92),
        .paragraphStyle: para,
    ])
    title.draw(in: NSRect(x: 0, y: 322, width: size.width, height: 30))
    let sub = NSAttributedString(string: "then launch it and press ⌃⌥Space anywhere", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.5),
        .paragraphStyle: para,
    ])
    sub.draw(in: NSRect(x: 0, y: 298, width: size.width, height: 20))

    // Arrow between the icons (they're centred at x=160 and x=500, y=200)
    let y: CGFloat = 200
    let path = NSBezierPath()
    path.lineWidth = 4; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: NSPoint(x: 256, y: y)); path.line(to: NSPoint(x: 396, y: y))
    path.move(to: NSPoint(x: 376, y: y + 16)); path.line(to: NSPoint(x: 400, y: y)); path.line(to: NSPoint(x: 376, y: y - 16))
    NSColor(calibratedWhite: 1, alpha: 0.55).setStroke()
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
try! render(scale: 1).write(to: dir.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: dir.appendingPathComponent("background@2x.png"))
print("wrote background.png + background@2x.png")
