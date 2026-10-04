import AppKit
import Foundation

// Offscreen artwork only; this script never launches the application or captures UI.
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        NSColor(calibratedRed: 0.07, green: 0.14, blue: 0.20, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210).fill()
        NSColor(calibratedRed: 0.00, green: 0.45, blue: 0.42, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 175, y: 175, width: 674, height: 674)).fill()
        NSColor.white.setStroke()
        let sun = NSBezierPath(ovalIn: NSRect(x: 364, y: 364, width: 296, height: 296))
        sun.lineWidth = 36; sun.stroke()
        for ray in 0..<8 {
            let angle = CGFloat(ray) * .pi / 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 512 + cos(angle) * 215, y: 512 + sin(angle) * 215))
            path.line(to: NSPoint(x: 512 + cos(angle) * 278, y: 512 + sin(angle) * 278))
            path.lineWidth = 36; path.lineCapStyle = .round; path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: outputURL.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
