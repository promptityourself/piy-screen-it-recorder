import AppKit
import SwiftUI

/// The bar before a recording, as QuickTime's ⌘⇧5: what to record, the options, and Record.
/// Shown with AreaPicker's setup mode, which shows the area on screen and lets you drag it.
@MainActor
enum SetupBar {
    private static var panel: NSPanel?

    static func show(on screen: NSScreen) {
        hide()
        let host = NSHostingView(rootView: SetupBarView())
        let size = host.fittingSize
        let p = BarPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: AreaPicker.level.rawValue + 1)  // above the cover, under menus
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false  // a panel's default; a menu bar app is often not the active app
        p.contentView = host
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: (f.midX - size.width / 2).rounded(), y: f.minY + 40))
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
        // SwiftUI sizes some controls (the Record button's title) only after the first layout.
        DispatchQueue.main.async { fit() }
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// The bar grows or shrinks with its contents (a display name, the Selected area segment).
    static func fit() {
        guard let panel, let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let f = panel.frame
        panel.setFrame(NSRect(x: (f.midX - size.width / 2).rounded(), y: f.minY, width: size.width, height: size.height),
                       display: true)
    }
}

private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct SetupBarView: View {
    @ObservedObject private var area = RecordArea.shared
    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var clicks = ClickHighlight.shared

    var body: some View {
        HStack(spacing: 12) {
            Button { AreaPicker.close() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")

            Divider().frame(height: 28)

            Picker("Display", selection: displayBinding) {
                Text("All Displays").tag(String?.none)
                ForEach(RecordArea.displays(), id: \.uuid) { Text($0.name).tag(Optional($0.uuid)) }
            }
            .labelsHidden()
            .fixedSize()

            Picker("Area", selection: presetBinding) {
                ForEach(RecordArea.Preset.allCases.filter { $0 != .custom || area.custom != nil }) { p in
                    Text(p == .custom ? "Selected" : p == .full ? "Full" : p == .left ? "Left" : "Right").tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(area.display == nil)

            Divider().frame(height: 28)

            Menu("Options") {
                Picker("Microphone", selection: $rec.micID) {
                    Text("None").tag(String?.none)
                    ForEach(rec.mics, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                Picker("Camera", selection: $rec.cameraID) {
                    let cams = CameraRecorder.devices
                    let labels = CameraRecorder.labels(for: cams)
                    Text("None").tag(String?.none)
                    ForEach(cams, id: \.uniqueID) { Text(labels[$0.uniqueID]!).tag(Optional($0.uniqueID)) }
                }
                Picker("Countdown", selection: $rec.startCountdown) {
                    ForEach(Countdown.choices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
                }
                Menu("App Sound: \(rec.appSoundApps.isEmpty ? "None" : rec.appSoundApps.map(Recorder.appName).joined(separator: ", "))") {
                    ForEach(rec.soundAppChoices, id: \.id) { Toggle($0.name, isOn: rec.soundApp($0.id)) }
                    Divider()
                    Button("Choose App…") { rec.chooseSoundApp() }
                }
                Picker("Highlight Clicks", selection: $clicks.mode) {
                    ForEach(ClickHighlight.Mode.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Text("Saves to \(rec.folder.lastPathComponent)")
                Button("More Settings…") {
                    AreaPicker.close()
                    SettingsWindow.show(.recording)
                }
            }
            .fixedSize()

            Button { AreaPicker.confirm() } label: {
                Label("Record", systemImage: "record.circle.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .tint(Color(nsColor: ClickHighlight.red))
            .keyboardShortcut(.defaultAction)
            .help("Start recording (Enter or ⌃⌥⇧R)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onReceive(area.objectWillChange) { _ in DispatchQueue.main.async { SetupBar.fit() } }
    }

    private var displayBinding: Binding<String?> {
        Binding(get: { area.display }, set: { uuid in
            // A display on its own starts whole; All Displays clears the area.
            area.choose(display: uuid, .full)
            AreaPicker.reload()
        })
    }

    private var presetBinding: Binding<RecordArea.Preset> {
        Binding(get: { area.preset }, set: { p in
            area.choose(display: area.display, p)
            AreaPicker.reload()
        })
    }
}
