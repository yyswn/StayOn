// Draws the 1024px app icon: a warm sun on a night-blue rounded square.
// Usage: make-icon <output.png>
import AppKit

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { exit(1) }
NSGraphicsContext.current = context

// Apple's icon grid leaves a margin around the rounded square.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.30, alpha: 1),
           ending: NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.12, alpha: 1))?
    .draw(in: shape, angle: -90)

let center = NSPoint(x: 512, y: 512)
NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.20, alpha: 1).setFill()
NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.20, alpha: 1).setStroke()
NSBezierPath(ovalIn: NSRect(x: center.x - 150, y: center.y - 150, width: 300, height: 300)).fill()
for ray in 0..<8 {
    let angle = CGFloat(ray) * .pi / 4
    let line = NSBezierPath()
    line.lineWidth = 48
    line.lineCapStyle = .round
    line.move(to: NSPoint(x: center.x + cos(angle) * 215, y: center.y + sin(angle) * 215))
    line.line(to: NSPoint(x: center.x + cos(angle) * 300, y: center.y + sin(angle) * 300))
    line.stroke()
}

context.flushGraphics()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
