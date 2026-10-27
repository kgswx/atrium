import AppKit
import AtriumCore

/// Draws the macOS folder in another colour, keeping its shading, with a symbol on the front.
enum FolderArt {
    static func color(_ color: FolderColor) -> NSColor {
        switch color {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }

    static func image(base: NSImage, color: FolderColor?, symbol: String?, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            base.draw(in: rect)
            if let color {
                // "Color" blending takes the hue from the paint and the light and shade from the folder.
                context.setBlendMode(.color)
                Self.color(color).setFill()
                context.fill(rect)
                base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            }
            context.endTransparencyLayer()

            if let symbol, let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                // White on the folder's front panel reads at list sizes, where a darker shade blurs into the colour;
                // larger in proportion when the icon is small.
                let height = rect.height * (rect.height <= 24 ? 0.52 : 0.40)
                let config = NSImage.SymbolConfiguration(pointSize: height, weight: .bold).applying(.init(paletteColors: [.white]))
                if let tinted = glyph.withSymbolConfiguration(config) {
                    let fit = min(height / tinted.size.height, rect.width * 0.56 / tinted.size.width, 1.6)
                    let w = tinted.size.width * fit, h = tinted.size.height * fit
                    tinted.draw(in: NSRect(x: rect.midX - w / 2, y: rect.minY + rect.height * 0.38 - h / 2, width: w, height: h))
                }
            }
            return true
        }
    }

    /// A round swatch for the colour menu.
    static func swatch(_ color: FolderColor?) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if let color {
                Self.color(color).setFill()
                dot.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                dot.stroke()
            }
            return true
        }
    }
}
