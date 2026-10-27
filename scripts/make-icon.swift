// Renders the app icon (a folder under a skylight, on a teal-to-indigo square) into an .iconset folder for iconutil.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let square = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.62, blue: 0.66, alpha: 1),
                        NSColor(red: 0.24, green: 0.25, blue: 0.62, alpha: 1)])!.draw(in: square, angle: -70)

    // The skylight: a soft band of light falling from the top edge.
    NSGraphicsContext.current?.saveGraphicsState()
    square.addClip()
    let beam = NSBezierPath()
    beam.move(to: NSPoint(x: s * 0.36, y: rect.maxY))
    beam.line(to: NSPoint(x: s * 0.64, y: rect.maxY))
    beam.line(to: NSPoint(x: s * 0.78, y: s * 0.30))
    beam.line(to: NSPoint(x: s * 0.22, y: s * 0.30))
    beam.close()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.30), NSColor(white: 1, alpha: 0.0)])!.draw(in: beam, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.36, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let folder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = folder.size
        folder.draw(in: NSRect(x: (s - size.width) / 2, y: s * 0.24, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
