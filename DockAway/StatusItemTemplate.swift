import AppKit

/// Turns the menu bar indicator into a template image, the way menu bar icons
/// are meant to be drawn. macOS tints a template itself, so the indicator turns
/// black or white together with every other icon in the menu bar instead of
/// waiting for DockAway to hear that the menu bar changed and redraw it.
enum StatusItemTemplate {
    /// Draws content built in white ink, where black marks a cutout, into a
    /// template image the given height. The width is trimmed to what's drawn.
    /// Nil if anything has color, which a template can't keep, or nothing was
    /// drawn.
    static func image(width: CGFloat, height: CGFloat, scales: [CGFloat],
                      draw: () -> Void) -> NSImage? {
        guard width > 0, height > 0 else { return nil }
        var reps: [(scale: CGFloat, image: CGImage)] = []
        var trimmed: ClosedRange<Int>?
        for scale in scales.sorted(by: >) {
            let pixelsWide = Int(ceil(width * scale)), pixelsHigh = Int(ceil(height * scale))
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide,
                                             pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: pixelsWide * 4, bitsPerPixel: 32),
                  let pixels = rep.bitmapData else { return nil }
            // In points before the context is made, so drawing is scaled up.
            rep.size = NSSize(width: width, height: height)
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            pixels.initialize(repeating: 0, count: pixelsWide * pixelsHigh * 4)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            draw()
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            guard convertToTemplate(pixels, count: pixelsWide * pixelsHigh) else { return nil }
            // Trim in points, from the sharpest copy, so every copy matches.
            if trimmed == nil {
                guard let columns = drawnColumns(pixels, width: pixelsWide, height: pixelsHigh) else { return nil }
                trimmed = Int(floor(CGFloat(columns.lowerBound) / scale))...Int(ceil(CGFloat(columns.upperBound + 1) / scale)) - 1
            }
            guard let image = rep.cgImage else { return nil }
            reps.append((scale, image))
        }
        guard let trimmed else { return nil }
        let size = NSSize(width: CGFloat(trimmed.count), height: height)
        let result = NSImage(size: size)
        for (scale, image) in reps {
            let crop = CGRect(x: CGFloat(trimmed.lowerBound) * scale, y: 0,
                              width: CGFloat(trimmed.count) * scale, height: CGFloat(image.height))
            guard let cropped = image.cropping(to: crop) else { return nil }
            let rep = NSBitmapImageRep(cgImage: cropped)
            rep.size = size
            result.addRepresentation(rep)
        }
        result.isTemplate = true
        return result
    }

    /// Turns premultiplied RGBA pixels into white whose opacity is their
    /// brightness: white ink stays, black cutouts go clear, and edges between
    /// them stay smooth. False if a pixel has color.
    static func convertToTemplate(_ pixels: UnsafeMutablePointer<UInt8>, count: Int) -> Bool {
        for index in 0..<count {
            let pixel = pixels + index * 4
            let red = Int(pixel[0]), green = Int(pixel[1]), blue = Int(pixel[2])
            guard max(red, green, blue) - min(red, green, blue) <= 24 else { return false }
            let brightness = UInt8((2126 * red + 7152 * green + 722 * blue + 5000) / 10000)
            pixel[0] = brightness
            pixel[1] = brightness
            pixel[2] = brightness
            pixel[3] = brightness
        }
        return true
    }

    /// The first and last pixel columns with anything drawn in them.
    static func drawnColumns(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> ClosedRange<Int>? {
        var first: Int?, last: Int?
        for x in 0..<width {
            for y in 0..<height where pixels[(y * width + x) * 4 + 3] > 0 {
                if first == nil { first = x }
                last = x
                break
            }
        }
        guard let first, let last else { return nil }
        return first...last
    }
}
