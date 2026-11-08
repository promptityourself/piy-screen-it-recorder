import AppKit
import Carbon.HIToolbox

/// What to record: every display in full (the default), or one display in full, one half, or
/// an area dragged with Select Area. Chosen in the menu or in Settings → Recording.
@MainActor
final class RecordArea: ObservableObject {
    static let shared = RecordArea()

    enum Preset: String, CaseIterable, Identifiable {
        case full, left, right, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .full: "Full screen"
            case .left: "Left half"
            case .right: "Right half"
            case .custom: "Selected area"
            }
        }
    }

    /// The chosen display's UUID (stable across restarts, unlike its display ID); nil = every display.
    @Published var display: String? {
        didSet { UserDefaults.standard.set(display, forKey: "areaDisplay") }
    }
    @Published var preset: Preset {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: "areaPreset") }
    }
    /// The dragged area as fractions of its display (origin top left), so it fits after a
    /// resolution change.
    @Published var custom: CGRect? {
        didSet {
            UserDefaults.standard.set(custom.map { [$0.minX, $0.minY, $0.width, $0.height] }, forKey: "areaCustom")
        }
    }

    init() {
        let d = UserDefaults.standard
        let c = d.array(forKey: "areaCustom") as? [Double] ?? []
        let saved = c.count == 4 ? CGRect(x: c[0], y: c[1], width: c[2], height: c[3]) : nil
        let p = d.string(forKey: "areaPreset").flatMap(Preset.init) ?? .full
        display = d.string(forKey: "areaDisplay")
        custom = saved
        preset = p == .custom && saved == nil ? .full : p
    }

    func choose(display uuid: String?, _ preset: Preset) {
        display = uuid
        self.preset = uuid == nil ? .full : preset
    }

    /// The part of a display `size` points large to record, in its points (origin top left);
    /// nil = all of it.
    func rect(in size: CGSize) -> CGRect? {
        let r: CGRect
        switch preset {
        case .full: return nil
        case .left: r = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: r = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .custom:
            guard let custom else { return nil }
            r = custom
        }
        return CGRect(x: r.minX * size.width, y: r.minY * size.height,
                      width: r.width * size.width, height: r.height * size.height).integral
    }

    /// The share of one display recorded: 1 for a full display, 0.5 for a half.
    var fraction: Double {
        switch preset {
        case .full: 1
        case .left, .right: 0.5
        case .custom: custom.map { $0.width * $0.height } ?? 1
        }
    }

    /// For the menu and the status line: "All displays", "Studio Display: left half".
    var summary: String {
        guard let display else { return "All displays" }
        let name = Self.names()[display] ?? "a display that is not connected"
        return "\(name): \(preset.label.lowercased())"
    }

    static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }

    static func uuid(_ screen: NSScreen) -> String? { Backlight.displayID(screen).flatMap(uuid) }

    /// Display names by UUID, numbering duplicates (two Studio Displays → "Studio Display (2)").
    static func names() -> [String: String] {
        let screens = NSScreen.screens
        let total = Dictionary(grouping: screens, by: \.localizedName).mapValues(\.count)
        var seen: [String: Int] = [:]
        var out: [String: String] = [:]
        for s in screens {
            guard let u = uuid(s) else { continue }
            seen[s.localizedName, default: 0] += 1
            out[u] = total[s.localizedName]! > 1 ? "\(s.localizedName) (\(seen[s.localizedName]!))" : s.localizedName
        }
        return out
    }

    /// Connected displays in NSScreen order, as (UUID, name).
    static func displays() -> [(uuid: String, name: String)] {
        let names = names()
        return NSScreen.screens.compactMap { uuid($0) }.map { ($0, names[$0] ?? $0) }
    }
}

/// Select Area: a dim cover on every display; drag a rectangle on one of them. That display
/// and area become the recording area. Esc cancels.
@MainActor
enum AreaPicker {
    private static var windows: [NSWindow] = []
    /// Smaller than this (points) is a click, not an area.
    static let minSide: CGFloat = 64

    static var isOpen: Bool { !windows.isEmpty }

    static func show() {
        guard !isOpen, !Recorder.shared.isRecording else { return }
        GreenScreen.shared.hide()
        Playback.shared.stop()
        for screen in NSScreen.screens {
            let w = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.contentView = PickerView(screen: screen)
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSApp.activate()
        (windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? windows.first)?.makeKey()
    }

    static func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// `rect` in the screen's view coordinates (origin bottom left).
    fileprivate static func picked(_ rect: CGRect, on screen: NSScreen) {
        close()
        guard let uuid = RecordArea.uuid(screen) else { return }
        let size = screen.frame.size
        let area = RecordArea.shared
        area.custom = CGRect(x: rect.minX / size.width, y: (size.height - rect.maxY) / size.height,
                             width: rect.width / size.width, height: rect.height / size.height)
        area.choose(display: uuid, .custom)
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            MainActor.assumeIsolated { AreaPicker.close() }
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class PickerView: NSView {
    private let screen: NSScreen
    private var start: NSPoint?
    private var current: NSPoint?

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        let r = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                       width: abs(current.x - start.x), height: abs(current.y - start.y))
        return r.intersection(bounds).integral
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let rect = selection
        start = nil
        current = nil
        needsDisplay = true
        if let rect, rect.width >= AreaPicker.minSide, rect.height >= AreaPicker.minSide {
            MainActor.assumeIsolated { AreaPicker.picked(rect, on: screen) }
        }
    }

    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        let hint = "Drag the area to record. Esc cancels."
        if let r = selection {
            r.fill(using: .clear)  // the chosen area shows through, undimmed
            ClickHighlight.red.setStroke()
            let frame = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
            frame.lineWidth = 3
            frame.stroke()
            let px = screen.backingScaleFactor
            label("\(Int(r.width * px)) × \(Int(r.height * px)) px", at: NSPoint(x: r.midX, y: r.minY - 30))
        } else {
            label(hint, at: NSPoint(x: bounds.midX, y: bounds.midY))
        }
    }

    private func label(_ text: String, at centre: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        var box = NSRect(x: centre.x - size.width / 2 - 12, y: centre.y - size.height / 2 - 6,
                         width: size.width + 24, height: size.height + 12)
        box.origin.y = max(8, min(bounds.maxY - box.height - 8, box.minY))
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        s.draw(at: NSPoint(x: box.minX + 12, y: box.minY + 6), withAttributes: attrs)
    }
}
