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
        Tags.shared.adding = false
    }

    /// Typing goes to the bar: our app active, the bar the key window.
    static func focus() {
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
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

/// The setup bar's "new tag" field: Enter adds the tag and ticks it, Esc cancels.
private struct NewTagField: View {
    @ObservedObject private var tags = Tags.shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag").foregroundStyle(.secondary)
            TextField("New tag", text: $tags.barDraft, prompt: Text("New tag"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($focused)
                .onSubmit(add)
                .onExitCommand { tags.adding = false }
            Button("Add", action: add).disabled(Tags.clean(tags.barDraft).isEmpty)
            Button { tags.adding = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Cancel (Esc)")
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func add() {
        if tags.add(tags.barDraft) { tags.adding = false }
    }
}

private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// QuickTime's dark bar, in two rows: what to record and Record on top, one pop-up per option
/// (icon + current value) below.
private struct SetupBarView: View {
    @ObservedObject private var area = RecordArea.shared
    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var clicks = ClickHighlight.shared
    @ObservedObject private var tags = Tags.shared

    var body: some View {
        VStack(spacing: 10) {
            // What to record, and Record.
            HStack(spacing: 10) {
                Button { AreaPicker.close() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(tags.adding ? nil : .cancelAction)  // Esc in the tag field cancels only that
                .help("Close (Esc)")

                separator

                chip("display", displayName, help: "Which display to record") {
                    Picker("Display", selection: displayBinding) {
                        Text("All Displays").tag(String?.none)
                        ForEach(RecordArea.displays(), id: \.uuid) { Text($0.name).tag(Optional($0.uuid)) }
                    }
                    .pickerStyle(.inline)
                }

                Picker("Area", selection: presetBinding) {
                    ForEach(RecordArea.Preset.allCases.filter { $0 != .custom || area.custom != nil }) { p in
                        Text(p == .custom ? "Selected" : p == .full ? "Full" : p == .left ? "Left" : "Right").tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(area.display == nil)

                Spacer(minLength: 24)
                Button { AreaPicker.confirm() } label: {
                    Label("Record", systemImage: "record.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()
                .tint(Color(nsColor: ClickHighlight.red))
                .keyboardShortcut(tags.adding ? nil : .defaultAction)  // Enter in the tag field adds the tag
                .help("Start recording (Enter or ⌃⌥⇧R)")
            }
            Divider().opacity(0.5)
            // How: one pop-up per option.
            HStack(spacing: 8) {
                if tags.adding {
                    NewTagField()
                } else {
                    chip(tags.active.isEmpty ? "tag.slash" : "tag", tags.summary,
                         help: "Tags: what the recording is about, saved in recording.json") {
                        TagItems {
                            tags.barDraft = ""
                            tags.adding = true
                            SetupBar.focus()
                        }
                        Button("Edit Tags…") { open(.tags) }
                    }
                }

                chip(rec.micID == nil ? "mic.slash" : "mic", micName, help: "Microphone: records to mic.wav") {
                    Picker("Microphone", selection: $rec.micID) {
                        Text("None").tag(String?.none)
                        ForEach(rec.mics, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                    }
                    .pickerStyle(.inline)
                }

                chip(rec.appSoundApps.isEmpty ? "speaker.slash" : "speaker.wave.2", soundName,
                     help: "App sound: each ticked app records to its own file") {
                    ForEach(rec.soundAppChoices, id: \.id) { Toggle($0.name, isOn: rec.soundApp($0.id)) }
                    Divider()
                    Button("Choose App…") { rec.chooseSoundApp() }
                    Button("Sound Settings…") { open(.sound) }
                }

                chip(rec.cameraID == nil ? "video.slash" : "video", cameraName, help: "Camera: records to camera.mov") {
                    Picker("Camera", selection: $rec.cameraID) {
                        let cams = CameraRecorder.devices
                        let labels = CameraRecorder.labels(for: cams)
                        Text("None").tag(String?.none)
                        ForEach(cams, id: \.uniqueID) { Text(labels[$0.uniqueID]!).tag(Optional($0.uniqueID)) }
                    }
                    .pickerStyle(.inline)
                }

                chip("timer", rec.startCountdown == 0 ? "No countdown" : "\(rec.startCountdown) s",
                     help: "Start countdown with sync tones") {
                    Picker("Countdown", selection: $rec.startCountdown) {
                        ForEach(Countdown.choices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
                    }
                    .pickerStyle(.inline)
                }

                chip("cursorarrow.click", clicks.mode == .off ? "No clicks" : "Clicks", help: "Highlight mouse clicks") {
                    Picker("Highlight Clicks", selection: $clicks.mode) {
                        ForEach(ClickHighlight.Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                }

                Spacer(minLength: 12)
                Button { open(.recording) } label: {
                    Image(systemName: "gearshape").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings (saves to \(rec.folder.lastPathComponent))")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .onReceive(area.objectWillChange) { _ in DispatchQueue.main.async { SetupBar.fit() } }
        .onReceive(rec.objectWillChange) { _ in DispatchQueue.main.async { SetupBar.fit() } }
        .onReceive(tags.objectWillChange) { _ in DispatchQueue.main.async { SetupBar.fit() } }
    }

    private var separator: some View { Divider().frame(height: 26) }

    /// One option: a pop-up that shows its icon and current value.
    private func chip<Content: View>(_ icon: String, _ value: String, help: String,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        Menu(content: content) {
            Label(value, systemImage: icon).labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help(help)
    }

    private func open(_ tab: SettingsWindow.Tab) {
        AreaPicker.close()
        SettingsWindow.show(tab)
    }

    private var displayName: String {
        area.display.flatMap { RecordArea.names()[$0] } ?? "All Displays"
    }

    private var micName: String {
        rec.micID.flatMap { id in rec.mics.first { $0.uniqueID == id }?.localizedName } ?? "No mic"
    }

    private var cameraName: String {
        rec.cameraID.flatMap { id in CameraRecorder.labels(for: CameraRecorder.devices)[id] } ?? "No camera"
    }

    private var soundName: String {
        switch rec.appSoundApps.count {
        case 0: "No app sound"
        case 1: Recorder.appName(rec.appSoundApps[0])
        case let n: "\(n) apps"
        }
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
