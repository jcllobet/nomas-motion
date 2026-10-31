import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: render-app-icon.swift <output-iconset-dir>\n", stderr)
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let icons: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func drawIcon(pixels: Int) throws -> Data {
    guard
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
        ),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else {
        throw IconError.renderSetupFailed
    }

    rep.size = NSSize(width: pixels, height: pixels)
    let size = CGFloat(pixels)
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    NSColor.clear.setFill()
    bounds.fill()

    let background = bounds.insetBy(dx: size * 0.075, dy: size * 0.075)
    NSColor(calibratedWhite: 0.10, alpha: 1.0).setFill()
    NSBezierPath(roundedRect: background, xRadius: size * 0.22, yRadius: size * 0.22).fill()

    NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
    let border = NSBezierPath(roundedRect: background, xRadius: size * 0.22, yRadius: size * 0.22)
    border.lineWidth = max(1.0, size * 0.014)
    border.stroke()

    let dotRadius = max(1.1, size * 0.040)
    let startX = size * 0.25
    let startY = size * 0.28
    let columnGap = size * 0.125
    let rowGap = size * 0.145

    for column in 0..<5 {
        let railColumn = column == 0 || column == 4
        NSColor(calibratedWhite: railColumn ? 1.0 : 0.50, alpha: railColumn ? 0.96 : 0.34).setFill()
        for row in 0..<4 {
            let x = startX + CGFloat(column) * columnGap
            let y = startY + CGFloat(row) * rowGap
            NSBezierPath(
                ovalIn: NSRect(
                    x: x - dotRadius,
                    y: y - dotRadius,
                    width: dotRadius * 2.0,
                    height: dotRadius * 2.0
                )
            ).fill()
        }
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw IconError.pngEncodingFailed
    }
    return png
}

for icon in icons {
    let png = try drawIcon(pixels: icon.pixels)
    try png.write(to: outputDirectory.appendingPathComponent(icon.name))
}

enum IconError: Error {
    case renderSetupFailed
    case pngEncodingFailed
}
