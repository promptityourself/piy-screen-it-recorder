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

    /// The part of the chosen display to record, as fractions of it (origin top left); nil = all of it.
    var unitRect: CGRect? {
        switch preset {
        case .full: nil
        case .left: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .custom: custom
        }
    }

    /// The part of a display `size` points large to record, in its points (origin top left);
    /// nil = all of it.
    func rect(in size: CGSize) -> CGRect? {
        unitRect.map { Self.scale($0, to: size).integral }
    }

    static func scale(_ unit: CGRect, to size: CGSize) -> CGRect {
        CGRect(x: unit.minX * size.width, y: unit.minY * size.height,
               width: unit.width * size.width, height: unit.height * size.height)
    }

    /// A unit rect (origin top left) on `screen`, in global screen coordinates (origin bottom left).
    static func frame(_ unit: CGRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX + unit.minX * f.width, y: f.maxY - unit.maxY * f.height,
                      width: unit.width * f.width, height: unit.height * f.height).integral
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

/// Select Area: a dim cover on every display, showing the current area (a dragged one or a
/// half) if one is chosen. Drag inside it to move it, drag an edge or corner to resize it, or drag
/// anywhere else for a new one, on any display. Enter, a double-click or Use This Area takes it;
/// Esc cancels.
///
/// Setup mode (⌃⌥⇧R, Start Recording): the same cover plus the setup bar (SetupBar). There each
/// change applies at once, so the bar always shows the truth, and Enter / Record starts recording.
@MainActor
enum AreaPicker {
    enum Mode { case select, setup }
    private(set) static var mode = Mode.select
    private static var views: [PickerView] = []
    /// Under pop-up menus (level 101), so the setup bar's menus open above the cover; above the
    /// Dock and the menu bar.
    static let level = NSWindow.Level.statusBar
    /// Smaller than this (points) is a click, not an area.
    static let minSide: CGFloat = 64

    /// The area being chosen: its screen and its rect in that screen's view (origin bottom left).
    fileprivate static var selection: (screen: NSScreen, rect: CGRect)? {
        didSet { views.forEach { $0.needsDisplay = true; $0.window?.invalidateCursorRects(for: $0) } }
    }

    static var isOpen: Bool { !views.isEmpty }

    static func show(_ mode: Mode = .select) {
        guard !isOpen, !Recorder.shared.isRecording else { return }
        self.mode = mode
        GreenScreen.shared.hide()
        Playback.shared.stop()
        reload()
        for screen in NSScreen.screens {
            let w = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = level
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            let view = PickerView(screen: screen)
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            views.append(view)
        }
        NSApp.activate()
        let mouse = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        if mode == .setup {
            SetupBar.show(on: mouse ?? NSScreen.screens[0])
        } else {
            (views.first { $0.screen == selection?.screen ?? mouse } ?? views.first)?.window?.makeKey()
        }
    }

    /// The selection from the saved area: a dragged area, a half, or a whole chosen display;
    /// none for all displays.
    static func reload() {
        let area = RecordArea.shared
        guard let uuid = area.display, let screen = NSScreen.screens.first(where: { RecordArea.uuid($0) == uuid }) else {
            selection = nil
            return
        }
        let r = RecordArea.scale(area.unitRect ?? CGRect(x: 0, y: 0, width: 1, height: 1), to: screen.frame.size)
        selection = (screen, CGRect(x: r.minX, y: screen.frame.height - r.maxY, width: r.width, height: r.height).integral)
    }

    static func close() {
        SetupBar.hide()
        views.forEach { $0.window?.orderOut(nil) }
        views.removeAll()
        selection = nil
    }

    /// Select mode: take the selection as the recording area and close. Setup mode: start recording.
    static func confirm() {
        if mode == .setup {
            close()
            Task { await Recorder.shared.start() }
            return
        }
        guard selection != nil else { return }
        apply()
        close()
    }

    /// Save the selection as the recording area (a dragged area on its display).
    fileprivate static func apply() {
        guard let (screen, rect) = selection, let uuid = RecordArea.uuid(screen) else { return }
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
        switch Int(event.keyCode) {
        case kVK_Escape: MainActor.assumeIsolated { AreaPicker.close() }
        case kVK_Return, kVK_ANSI_KeypadEnter: MainActor.assumeIsolated { AreaPicker.confirm() }
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class PickerView: NSView {
    let screen: NSScreen
    /// What a drag does: draw a new area, move the area, or move some of its edges.
    private enum Drag { case new(NSPoint), move(CGRect, NSPoint), resize(CGRect, NSPoint, Edges) }
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), bottom = Edges(rawValue: 4), top = Edges(rawValue: 8)
    }
    private var drag: Drag?
    private var before: (screen: NSScreen, rect: CGRect)?  // restored when a new drag is only a click
    private var rectAtDown: CGRect?  // to tell a real change from a click
    private static let grab: CGFloat = 10  // how near an edge counts as on it, in points

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var mine: CGRect? { AreaPicker.selection.flatMap { $0.screen == screen ? $0.rect : nil } }

    private func edges(at p: NSPoint, of r: CGRect) -> Edges {
        guard r.insetBy(dx: -Self.grab, dy: -Self.grab).contains(p) else { return [] }
        var e: Edges = []
        if abs(p.x - r.minX) <= Self.grab { e.insert(.left) } else if abs(p.x - r.maxX) <= Self.grab { e.insert(.right) }
        if abs(p.y - r.minY) <= Self.grab { e.insert(.bottom) } else if abs(p.y - r.maxY) <= Self.grab { e.insert(.top) }
        return e
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        // Only a real area gets move and resize cursors (a drag starts tiny).
        guard let r = mine, !r.isNull, r.width > 4 * Self.grab, r.height > 4 * Self.grab else { return }
        addCursorRect(r.insetBy(dx: Self.grab, dy: Self.grab), cursor: .openHand)
        let g = Self.grab
        addCursorRect(CGRect(x: r.minX - g, y: r.minY + g, width: 2 * g, height: r.height - 2 * g), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.maxX - g, y: r.minY + g, width: 2 * g, height: r.height - 2 * g), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.minX + g, y: r.minY - g, width: r.width - 2 * g, height: 2 * g), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: r.minX + g, y: r.maxY - g, width: r.width - 2 * g, height: 2 * g), cursor: .resizeUpDown)
        if let b = buttonRect(for: r) { addCursorRect(b, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeKey()
        rectAtDown = AreaPicker.selection?.rect
        if let r = mine {
            if let b = buttonRect(for: r), b.contains(p) { AreaPicker.confirm(); return }
            let e = edges(at: p, of: r)
            if !e.isEmpty { drag = .resize(r, p, e); return }
            if r.contains(p) {
                if event.clickCount == 2 { AreaPicker.confirm(); return }
                drag = .move(r, p)
                NSCursor.closedHand.set()
                return
            }
        }
        before = AreaPicker.selection
        drag = .new(p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let b = bounds
        switch drag {
        case let .new(start)?:
            // An empty rect's `integral` is CGRect.null (infinite origin): keep the old one until it has size.
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
                .intersection(b).integral
            if !r.isNull, r.width >= 1, r.height >= 1 { AreaPicker.selection = (screen, r) }
        case let .move(r, start)?:
            var moved = r.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            moved.origin.x = min(max(b.minX, moved.minX), b.maxX - moved.width)
            moved.origin.y = min(max(b.minY, moved.minY), b.maxY - moved.height)
            AreaPicker.selection = (screen, moved.integral)
        case let .resize(r, start, e)?:
            let dx = p.x - start.x, dy = p.y - start.y
            let m = AreaPicker.minSide
            var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
            if e.contains(.left) { x0 = min(max(b.minX, x0 + dx), x1 - m) }
            if e.contains(.right) { x1 = max(min(b.maxX, x1 + dx), x0 + m) }
            if e.contains(.bottom) { y0 = min(max(b.minY, y0 + dy), y1 - m) }
            if e.contains(.top) { y1 = max(min(b.maxY, y1 + dy), y0 + m) }
            AreaPicker.selection = (screen, CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .new = drag, let r = mine, r.width < AreaPicker.minSide || r.height < AreaPicker.minSide {
            AreaPicker.selection = before  // a click, or too small: keep what was there
        }
        // Setup mode applies a real change at once (the bar shows it); select mode waits for Enter.
        if drag != nil, AreaPicker.mode == .setup, let sel = AreaPicker.selection, sel.screen == screen, sel.rect != rectAtDown {
            AreaPicker.apply()
        }
        drag = nil
        window?.invalidateCursorRects(for: self)
    }

    /// "Use This Area" under the area, or above it near the bottom of the display.
    private func buttonRect(for r: CGRect) -> CGRect? {
        guard AreaPicker.mode == .select else { return nil }  // setup mode: the bar's Record button
        let size = (Self.button as NSString).size(withAttributes: Self.attrs)
        let w = size.width + 24, h = size.height + 12
        var y = r.minY - h - 12
        if y < 8 { y = r.maxY + 12 }
        if y + h > bounds.maxY - 8 { y = r.minY + 12 }  // a nearly full-height area: inside it
        let x = min(max(8, r.midX - w / 2), bounds.maxX - w - 8)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static let button = "Use This Area (Enter)"
    private static let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white,
    ]

    override func draw(_ dirty: NSRect) {
        let setup = AreaPicker.mode == .setup
        if setup, AreaPicker.selection == nil {
            // All displays: nothing dimmed, every display records whole.
            label("Records this whole display · drag for an area instead", at: NSPoint(x: bounds.midX, y: bounds.maxY - 60), size: 16)
            NSColor.black.withAlphaComponent(0.01).setFill()  // still takes the drag (alpha 0 passes clicks through)
            bounds.fill()
            return
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        guard let r = mine else {
            label(AreaPicker.selection == nil ? "Drag the area to record. Esc cancels."
                  : setup ? "Not recorded · drag here for an area on this display"
                  : "Drag here for a new area on this display.", at: NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        r.fill(using: .clear)  // the chosen area shows through, undimmed
        // …but not fully transparent: macOS sends clicks on alpha-0 pixels to the window below,
        // and a drag inside the area must move it.
        NSColor.black.withAlphaComponent(0.01).setFill()
        r.fill()
        ClickHighlight.red.setStroke()
        let frame = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
        frame.lineWidth = 3
        frame.stroke()
        // Handles on the corners and edge midpoints.
        ClickHighlight.red.setFill()
        for x in [r.minX, r.midX, r.maxX] {
            for y in [r.minY, r.midY, r.maxY] where !(x == r.midX && y == r.midY) {
                NSBezierPath(rect: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)).fill()
            }
        }
        // The size of the file, as Recorder will write it.
        let px = Recorder.shared.pixelsPerPoint(width: screen.frame.width, scale: screen.backingScaleFactor)
        label("\(Recorder.pixels(r.width, px)) × \(Recorder.pixels(r.height, px)) px · drag to move or resize"
              + (setup ? "" : " · Esc cancels"),
              at: NSPoint(x: r.midX, y: r.maxY + 30), size: 16)
        if let b = buttonRect(for: r) {
            ClickHighlight.red.setFill()
            NSBezierPath(roundedRect: b, xRadius: 8, yRadius: 8).fill()
            (Self.button as NSString).draw(at: NSPoint(x: b.minX + 12, y: b.minY + 6), withAttributes: Self.attrs)
        }
    }

    private func label(_ text: String, at centre: NSPoint, size: CGFloat = 22) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        var box = NSRect(x: centre.x - sz.width / 2 - 12, y: centre.y - sz.height / 2 - 6,
                         width: sz.width + 24, height: sz.height + 12)
        box.origin.x = max(8, min(bounds.maxX - box.width - 8, box.minX))
        box.origin.y = max(8, min(bounds.maxY - box.height - 8, box.minY))
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        s.draw(at: NSPoint(x: box.minX + 12, y: box.minY + 6), withAttributes: attrs)
    }
}
