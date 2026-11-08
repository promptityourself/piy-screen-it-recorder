import AppKit

/// The S|R face in the menu bar: Resources/menubar.svg, drawn by tools/make-logo.py from the
/// Prompt It Yourself logo, as is the app icon.
enum Logo {
    private static let face: NSImage? = Bundle.main.url(forResource: "menubar", withExtension: "svg")
        .flatMap(NSImage.init(contentsOf:))

    static func menuBar(recording: Bool) -> NSImage {
        guard let face else { return text(recording: recording) }
        let height: CGFloat = 18
        let size = NSSize(width: (height * face.size.width / face.size.height).rounded(.up), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            face.draw(in: rect)
            if recording {
                NSColor.systemRed.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
        image.isTemplate = !recording  // red while recording, otherwise follows the menu bar
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
