import AppKit

/// What you see while recording, never in the files (Recorder excludes these windows from the
/// capture): the countdown number in the middle of each recorded area, everything else dimmed.
/// After "go" the number goes; an area recording keeps its frame and a light dim until Stop, so
/// you always see where the recording is.
@MainActor
enum RecordingOverlay {
    enum Phase: Equatable { case starting, count(Int), recording }

    /// PIY amber and ink: the tile the number sits on.
    static let amber = NSColor(srgbRed: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0x0A / 255, green: 0x0D / 255, blue: 0x16 / 255, alpha: 1)

    private static var views: [OverlayView] = []

    /// Window numbers to leave out of the capture.
    static var windowNumbers: [Int] { views.compactMap { $0.window?.windowNumber } }

    /// One window per display. `areas`: the recorded rect per display, in global screen
    /// coordinates; a display missing from it is not recorded and is dimmed whole.
    static func show(areas: [NSScreen: CGRect]) {
        hide()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            // Above the colour screen and Playback (.screenSaver) and the click ripples (+1).
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true  // you keep working while it shows
            w.isReleasedWhenClosed = false
            let area = areas[screen].map { $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
            let view = OverlayView(area: area, full: area == CGRect(origin: .zero, size: screen.frame.size))
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            views.append(view)
        }
    }

    static func set(_ phase: Phase) {
        views.forEach { $0.phase = phase }
        // A whole-display recording needs nothing on screen once it runs.
        if phase == .recording { views.filter(\.full).forEach { $0.window?.orderOut(nil) } }
    }

    static func hide() {
        views.forEach { $0.window?.orderOut(nil) }
        views.removeAll()
    }
}

private final class OverlayView: NSView {
    let area: CGRect?  // in this view; nil = this display is not recorded
    let full: Bool
    var phase = RecordingOverlay.Phase.starting { didSet { needsDisplay = true } }

    init(area: CGRect?, full: Bool) {
        self.area = area
        self.full = full
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let counting = phase != .recording
        // Dim outside the area: strong while counting, light while recording.
        if !full {
            NSColor.black.withAlphaComponent(counting ? 0.6 : 0.3).setFill()
            bounds.fill()
            if let area { area.fill(using: .clear) }
        }
        guard let area else { return }
        if !full {
            ClickHighlight.red.setStroke()
            let frame = NSBezierPath(rect: area.insetBy(dx: -2, dy: -2))
            frame.lineWidth = 4
            frame.stroke()
        }
        let text: String
        switch phase {
        case .starting: text = "…"
        case let .count(n): text = "\(n)"
        case .recording: return
        }
        // The number on an amber tile in the middle of the area.
        let side = min(area.width, area.height) * 0.3
        let tile = CGRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
        RecordingOverlay.amber.setFill()
        NSBezierPath(roundedRect: tile, xRadius: side * 0.17, yRadius: side * 0.17).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side * 0.7, weight: .heavy),
            .foregroundColor: RecordingOverlay.ink,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2), withAttributes: attrs)
    }
}
