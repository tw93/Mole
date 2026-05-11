import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: GenerateIcon.swift <output-iconset>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let specs: [(name: String, points: Int, scale: Int)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2)
]

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let outer = NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88)
    let outerPath = NSBezierPath(roundedRect: outer, xRadius: size * 0.22, yRadius: size * 0.22)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.02, green: 0.35, blue: 0.88, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.72, blue: 0.46, alpha: 1)
    ])?.draw(in: outerPath, angle: 45)

    NSColor.white.withAlphaComponent(0.16).setFill()
    NSBezierPath(ovalIn: NSRect(x: size * 0.18, y: size * 0.54, width: size * 0.62, height: size * 0.30)).fill()

    NSColor.white.withAlphaComponent(0.92).setFill()
    let handle = NSBezierPath(roundedRect: NSRect(x: size * 0.31, y: size * 0.36, width: size * 0.38, height: size * 0.09), xRadius: size * 0.045, yRadius: size * 0.045)
    handle.fill()
    let tray = NSBezierPath(roundedRect: NSRect(x: size * 0.23, y: size * 0.24, width: size * 0.54, height: size * 0.17), xRadius: size * 0.08, yRadius: size * 0.08)
    tray.fill()

    let letterRect = NSRect(x: 0, y: size * 0.48, width: size, height: size * 0.34)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.30, weight: .black),
        .foregroundColor: NSColor.white,
        .paragraphStyle: style
    ]
    NSString(string: "M").draw(in: letterRect, withAttributes: attributes)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for spec in specs {
    let pixels = spec.points * spec.scale
    let rep = drawIcon(pixels: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("failed to render \(spec.name)\n", stderr)
        exit(1)
    }
    try data.write(to: outputURL.appendingPathComponent(spec.name))
}
