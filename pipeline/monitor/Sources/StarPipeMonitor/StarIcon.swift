import AppKit
import StarPipeMonitorCore

/// The star drawn in the colour of the pipeline's state. The images are plain bitmaps, not template images, so
/// the menu bar and the Dock show the colour instead of tinting it monochrome.
enum StarIcon {
    static func color(for state: PipelineState) -> NSColor {
        switch state {
        case .red: .systemRed
        case .green: .systemGreen
        case .grey: .systemGray
        }
    }

    /// A square-ish star of the given point size in the state's colour.
    static func image(for state: PipelineState, pointSize: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color(for: state)]))
        guard let symbol = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Pipeline \(state)")?
            .withSymbolConfiguration(config)
        else { return NSImage() }
        // Draw into a bitmap so the colour survives whatever the menu bar does to symbol images.
        let drawn = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        drawn.isTemplate = false
        return drawn
    }

    /// The menu-bar star, at menu-bar size.
    static func menuBarImage(for state: PipelineState) -> NSImage { image(for: state, pointSize: 16) }

    /// The Dock icon: the same star, large, centred on a transparent square.
    static func dockImage(for state: PipelineState) -> NSImage {
        let star = image(for: state, pointSize: 400)
        let side: CGFloat = 512
        let icon = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let scale = min(rect.width * 0.9 / star.size.width, rect.height * 0.9 / star.size.height)
            let w = star.size.width * scale, h = star.size.height * scale
            star.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            return true
        }
        icon.isTemplate = false
        return icon
    }
}
