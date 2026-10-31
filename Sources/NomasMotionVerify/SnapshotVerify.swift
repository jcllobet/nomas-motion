import AppKit
import Foundation
import NomasMotionCore
import NomasMotionOverlay


enum SnapshotVerify {
    @MainActor
    static func run(
        outputPath: String,
        modeName: String,
        motionOffset: CGSize = .zero
    ) throws {
        guard let mode = SnapshotMode(rawValue: modeName) else {
            throw SnapshotError.invalidMode(modeName)
        }
        
        
        let size = NSSize(width: 1200, height: 760)
        let bounds = NSRect(origin: .zero, size: size)
        let view = DotOverlayView(frame: bounds)
        view.dotColorMode = mode.dotColorMode

        // Snapshot the production comfort renderer: four tracks on each side.
        // This stays offscreen and never opens the overlay window.
        view.updateSideRailFrame(motionOffset: motionOffset)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw SnapshotError.renderFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        mode.backgroundColor.setFill()
        bounds.fill()
        view.draw(bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed
        }

        let pixelCounts = countPixels(in: bitmap, mode: mode)
        let dotPixels = pixelCounts.dots
        guard dotPixels > 100 else {
            throw SnapshotError.noDotsRendered(dotPixels: dotPixels, mode: mode.rawValue)
        }

        let centerDotPixels = pixelCounts.centerDots
        guard centerDotPixels == 0 else {
            throw SnapshotError.centerOccluded(dotPixels: centerDotPixels, mode: mode.rawValue)
        }

        try png.write(to: URL(fileURLWithPath: outputPath))
        print(outputPath)
        print("mode=\(mode.rawValue) dotPixels=\(dotPixels) width=\(bitmap.pixelsWide) height=\(bitmap.pixelsHigh)")
    }

    private static func countPixels(in bitmap: NSBitmapImageRep, mode: SnapshotMode) -> (dots: Int, centerDots: Int) {
        let centerLeft = Int(Double(bitmap.pixelsWide) * 0.25)
        let centerRight = Int(Double(bitmap.pixelsWide) * 0.75)
        var dots = 0
        var centerDots = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y) else {
                    continue
                }
                if mode.matchesDotPixel(color) {
                    dots += 1
                    if x >= centerLeft, x < centerRight {
                        centerDots += 1
                    }
                }
            }
        }
        return (dots, centerDots)
    }
}

private enum SnapshotMode: String {
    case dark
    case light

    var backgroundColor: NSColor {
        switch self {
        case .dark:
            return .black
        case .light:
            return .white
        }
    }

    var dotColorMode: DotColorMode {
        switch self {
        case .dark:
            return .white
        case .light:
            return .black
        }
    }

    func matchesDotPixel(_ color: NSColor) -> Bool {
        guard color.alphaComponent > 0.5 else {
            return false
        }
        switch self {
        case .dark:
            return color.redComponent > 0.55 && color.greenComponent > 0.55 && color.blueComponent > 0.55
        case .light:
            return color.redComponent < 0.45 && color.greenComponent < 0.45 && color.blueComponent < 0.45
        }
    }
}

enum SnapshotError: Error {
    case renderFailed
    case noDotsRendered(dotPixels: Int, mode: String)
    case centerOccluded(dotPixels: Int, mode: String)
    case invalidMode(String)
}
