import AppKit

// Normalize the supplied artwork to a transparent square canvas without stretching it.
let arguments = CommandLine.arguments
precondition(arguments.count == 3, "Usage: icon.swift source.png output.png")
guard let source = NSImage(contentsOfFile: arguments[1]), source.size.width > 0, source.size.height > 0,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not load icon artwork or create its drawing canvas")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
NSColor.clear.setFill()
canvas.fill(using: .copy)
let scale = min(1024 / source.size.width, 1024 / source.size.height)
let width = source.size.width * scale, height = source.size.height * scale
source.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2, width: width, height: height),
            from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode app icon") }
try png.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
