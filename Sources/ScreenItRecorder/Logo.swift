import AppKit

/// The S|R tile in the menu bar: Resources/tile.svg and face.svg, drawn by tools/make-logo.py
/// from the Prompt It Yourself logo, as is the app icon. Red tile while recording.
enum Logo {
    /// Prompt It Yourself red, as the click ripple.
    static let red = NSColor(srgbRed: 0xE2 / 255, green: 0x34 / 255, blue: 0x2B / 255, alpha: 1)
    private static func svg(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    }
    private static let tile = svg("tile")
    private static let face = svg("face")

    static func menuBar(recording: Bool) -> NSImage {
        guard let tile, let face else { return text(recording: recording) }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            if recording {
                red.setFill()
                // The tile's corner radius: 17 in its 100×100 frame.
                NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.17, yRadius: rect.height * 0.17).fill()
                face.draw(in: rect)
            } else {
                tile.draw(in: rect)
            }
            return true
        }
        image.isTemplate = false  // the brand colours, on a light or a dark menu bar
        return image
    }

    /// Without the bundle (a bare `swift run`): the letters as text.
    private static func text(recording: Bool) -> NSImage {
        let text = "S|R" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .heavy),
            .foregroundColor: recording ? NSColor.systemRed : NSColor.black,
        ]
        let size = text.size(withAttributes: attrs)
        let image = NSImage(size: NSSize(width: ceil(size.width) + 2, height: 18), flipped: false) { rect in
            text.draw(at: NSPoint(x: 1, y: (rect.height - size.height) / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = !recording
        return image
    }
}
