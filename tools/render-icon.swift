// Renders the app icon's SVG masters (docs/logo) into AppIcon.icns: the small master for 16,
// 32 and 64 pixels, the full one from 128 up. Run through `just icon`.
import AppKit

func render(_ svg: String, size: Int, to path: String) throws {
    guard let image = NSImage(contentsOfFile: svg),
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)
    else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: svg])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: URL(fileURLWithPath: path))
}

let (full, small, iconset) = (CommandLine.arguments[1], CommandLine.arguments[2], CommandLine.arguments[3])
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try render(pixels <= 64 ? small : full, size: pixels, to: iconset + "/" + name)
    }
}
