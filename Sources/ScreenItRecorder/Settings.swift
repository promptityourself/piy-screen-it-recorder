import AVFoundation
import Combine
import AppKit
import SwiftUI

/// AppKit-hosted SwiftUI windows, one per title: open reliably from a menu bar app, the hotkeys,
/// or a launch flag.
@MainActor
enum HostedWindow {
    private static var windows: [String: NSWindow] = [:]

    static func show<V: View>(_ title: String, _ view: @autoclosure () -> V) {
        let window = windows[title] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view()))
            w.title = title
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            windows[title] = w
            return w
        }()
        NSApp.activate()  // a menu bar app's window opens behind the front app otherwise
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum SettingsWindow {
    enum Tab: Hashable { case recording, sound, colour, shortcuts, permissions }

    /// The selected tab, so the menu can open Settings on Permissions.
    final class Selection: ObservableObject {
        static let shared = Selection()
        @Published var tab = Tab.recording
    }

    static func show(_ tab: Tab? = nil) {
        if let tab { Selection.shared.tab = tab }
        HostedWindow.show("Screen It Recorder Settings", SettingsView())
    }
}

struct SettingsView: View {
    @ObservedObject private var selection = SettingsWindow.Selection.shared

    var body: some View {
        TabView(selection: $selection.tab) {
            RecordingTab().tabItem { Text("Recording") }.tag(SettingsWindow.Tab.recording)
            SoundTab().tabItem { Text("Sound") }.tag(SettingsWindow.Tab.sound)
            ColourTab().tabItem { Text("Screen Colour") }.tag(SettingsWindow.Tab.colour)
            ShortcutsTab().tabItem { Text("Shortcuts") }.tag(SettingsWindow.Tab.shortcuts)
            PermissionsTab().tabItem { Text("Permissions") }.tag(SettingsWindow.Tab.permissions)
        }
        .padding()
        .frame(width: 560, height: 640)  // a long tab scrolls instead of growing off the screen
    }
}

private struct RecordingTab: View {
    @ObservedObject private var rec = Recorder.shared

    var body: some View {
        Form {
            Section {
                Picker("Camera", selection: $rec.cameraID) {
                    let cams = CameraRecorder.devices
                    let labels = CameraRecorder.labels(for: cams)
                    Text("None").tag(String?.none)
                    ForEach(cams, id: \.uniqueID) { Text(labels[$0.uniqueID]!).tag(Optional($0.uniqueID)) }
                }
                if let cameraID = rec.cameraID {
                    Picker("Camera frame rate", selection: $rec.cameraFPS) {
                        ForEach(CameraRecorder.rates(cameraID: cameraID), id: \.self) { fps in
                            Text(fps == Int(Recorder.fps) ? "\(fps) fps (matches screens)" : "\(fps) fps").tag(fps)
                        }
                    }
                }
                Toggle("Show the setup bar before recording", isOn: $rec.setupBar)
                Picker("Start countdown", selection: $rec.startCountdown) {
                    ForEach(Countdown.choices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
                }
                Toggle("Hide desktop widgets while recording", isOn: $rec.hideWidgets)
                LabeledContent("Saves to") {
                    VStack(alignment: .trailing) {
                        Text(rec.folder.path(percentEncoded: false)).textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                        HStack {
                            if rec.folder.standardizedFileURL != Recorder.defaultFolder.standardizedFileURL {
                                Button("Use Default") { rec.folder = Recorder.defaultFolder }
                            }
                            Button("Change…") { chooseFolder() }
                            Button("Open") { rec.openFolder() }
                        }
                    }
                }
            } footer: {
                if rec.isRecording {
                    Text("Stop the recording to change these.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(rec.isRecording)

            Section {
                Picker("Quality", selection: $rec.quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
                Picker("Resolution", selection: $rec.resolution) {
                    ForEach(Resolution.allCases) { Text($0.label).tag($0) }
                }
                Picker("Codec", selection: $rec.codec) {
                    ForEach(Codec.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Screen quality")
            } footer: {
                let gb = MeasuredRate.mbps(rec.codec, rec.resolution, rec.quality) * 3600 / 8 / 1000
                let mbs = rec.bytesPerSecond / 1_000_000
                Text("About \(Int(gb.rounded())) GB per hour for each display with moving content; a still "
                    + "screen uses much less. All displays write about \(Int(mbs.rounded())) MB/s"
                    + (mbs > 100 ? ", more than a 1 Gbit network drive can take: record to the internal disk." : ".")
                    + " The camera file does not change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(rec.isRecording)

            AreaSection()
            ClickSection()
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where Screen It Recorder saves recordings"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = rec.folder
        if panel.runModal() == .OK, let url = panel.url { rec.folder = url }
    }
}

/// The mic and the apps whose sound to record, each to its own file.
private struct SoundTab: View {
    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var search = SearchText.shared

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $rec.micID) {
                    Text("None").tag(String?.none)
                    ForEach(rec.mics, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
            } footer: {
                Text("Records to mic.wav, never into a screen file. The camera file has it too.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Search", text: $search.text, prompt: Text("Search apps"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(apps, id: \.id) { app in
                            Toggle(isOn: rec.soundApp(app.id)) {
                                HStack(spacing: 8) {
                                    Image(nsImage: Self.icon(app.id)).resizable().frame(width: 20, height: 20)
                                    Text(app.name)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 3)
                        }
                        if apps.isEmpty {
                            Text("No app matches.").foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                .frame(height: 260)
                HStack {
                    Text(rec.appSoundApps.isEmpty ? "No app sound records."
                         : "Records: " + rec.appSoundApps.map(Recorder.appName).sorted().joined(separator: ", "))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !rec.appSoundApps.isEmpty { Button("Untick All") { rec.appSoundApps = [] } }
                    Button("Choose App…") { rec.chooseSoundApp() }
                }
            } header: {
                Text("App sound")
            } footer: {
                Text("Each ticked app records to its own file, app-<name>.wav. The list shows running apps "
                    + "and the ones you ticked; Choose App… adds one that is not running. An app that opens "
                    + "during the recording records from then on. The screen files have only the countdown "
                    + "tones, to sync on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(rec.isRecording)
    }

    private var apps: [(id: String, name: String)] {
        let q = search.text.trimmingCharacters(in: .whitespaces)
        return rec.soundAppChoices.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
    }

    static func icon(_ id: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
}

/// The Sound tab's search text (no @State without Xcode's macros).
private final class SearchText: ObservableObject {
    static let shared = SearchText()
    @Published var text = ""
}

private struct AreaSection: View {
    @ObservedObject private var area = RecordArea.shared
    @ObservedObject private var rec = Recorder.shared

    var body: some View {
        Section {
            Picker("Display", selection: Binding(get: { area.display }, set: { area.choose(display: $0, area.preset) })) {
                Text("All displays").tag(String?.none)
                ForEach(RecordArea.displays(), id: \.uuid) { Text($0.name).tag(Optional($0.uuid)) }
                if let d = area.display, !RecordArea.displays().contains(where: { $0.uuid == d }) {
                    Text("Not connected").tag(Optional(d))
                }
            }
            Picker("Area", selection: $area.preset) {
                ForEach(RecordArea.Preset.allCases.filter { $0 != .custom || area.custom != nil }) { Text($0.label).tag($0) }
            }
            .disabled(area.display == nil)
            LabeledContent("Your own area") {
                Button("Select Area…") { AreaPicker.show() }
            }
        } header: {
            Text("What to record")
        } footer: {
            Text("All displays records each display in full, to its own file. One display records only "
                + "that display, in full, one half, or an area you drag with Select Area. The menu has the same choices.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(rec.isRecording)
    }
}

private struct ClickSection: View {
    @ObservedObject private var clicks = ClickHighlight.shared

    var body: some View {
        Section {
            Picker("Highlight clicks", selection: $clicks.mode) {
                ForEach(ClickHighlight.Mode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Ripple length", selection: $clicks.duration) {
                ForEach(ClickHighlight.durations, id: \.self) { Text($0 == 1 ? "1 second" : "\($0) seconds").tag($0) }
            }
            .disabled(clicks.mode == .off)
            Picker("Ripple size", selection: $clicks.size) {
                ForEach(ClickHighlight.Size.allCases) { Text($0.label).tag($0) }
            }
            .disabled(clicks.mode == .off)
        } header: {
            Text("Mouse clicks")
        } footer: {
            Text("Each click shows a red ripple in the recording. For a video you speed up, make the ripple "
                + "longer by the same factor: 10× faster needs 10 seconds. \"Always\" also shows it outside a recording, "
                + "so you can try it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ColourTab: View {
    @ObservedObject private var green = GreenScreen.shared

    var body: some View {
        Form {
            Section {
                Picker("Colour", selection: $green.shade) {
                    ForEach(GreenScreen.Shade.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Dim displays while the screen colour is on", isOn: $green.dim)
                LabeledContent("Display brightness") {
                    HStack {
                        Slider(value: $green.dimLevel, in: 0.1...1, step: 0.05)
                        Text("\(Int((green.dimLevel * 100).rounded()))%").monospacedDigit().frame(width: 40)
                    }
                }
                .disabled(!green.dim)
                Button("Preview \(green.shade.family) Screen") { green.show() }
            } footer: {
                Text("Dimming changes only the backlight. The recording keeps the exact colour. "
                    + "Press ⌃⌥G or Esc to end the preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsTab: View {
    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("Start / stop recording", value: "⌃⌥⇧R")
                LabeledContent("With the setup bar", value: "⌃⌥⇧R opens it, Enter or ⌃⌥⇧R starts, Esc closes")
            }
            Section("Screen colour") {
                LabeledContent("Green / blue screen on / off", value: "⌃⌥G  (Esc also turns it off)")
            }
            Section("Playback") {
                LabeledContent("Play / pause", value: "⌃⌥P  (Space too)")
                LabeledContent("Restart", value: "⌃⌥⇧P")
                LabeledContent("Stop", value: "Esc")
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
enum About {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let repo = URL(string: "https://github.com/promptityourself/piy-screen-it-recorder")!
    static let site = URL(string: "https://promptityourself.com/projects/screen-it-recorder/")!
    static let blurb = "Records every screen, the mic, and a camera if you want one, each to "
        + "its own file, ready to sync in Final Cut Pro."
    static let credit = "A Prompt It Yourself project. MIT licence. © 2026 Mergodon Limited."
    /// The same list, in the same order, as the promptityourself.com footer.
    static let channels: [(name: String, url: URL)] = [
        ("YouTube", "https://www.youtube.com/@promptityourself"),
        ("Facebook", "https://www.facebook.com/promptityourself"),
        ("Twitch", "https://www.twitch.tv/promptityourself"),
        ("X", "https://x.com/promptityoursel"),
        ("Threads", "https://www.threads.com/@prompt_it_yourself"),
        ("Instagram", "https://www.instagram.com/prompt_it_yourself/"),
        ("LinkedIn", "https://www.linkedin.com/company/promptityourself/"),
        ("Pinterest", "https://www.pinterest.com/promptityourself/"),
        ("TikTok", "https://www.tiktok.com/@promptityourself"),
        ("GitHub", "https://github.com/promptityourself"),
    ].map { ($0.0, URL(string: $0.1)!) }

    static func show() { HostedWindow.show("About Screen It Recorder", AboutView()) }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Screen It Recorder").font(.title2.bold())
            Text("Version \(About.version)").foregroundStyle(.secondary)
            Text(About.blurb).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("Prompt It Yourself", destination: About.site)
                Link("Source on GitHub", destination: About.repo)
            }
            Divider().padding(.vertical, 4)
            Text("Support").font(.headline)
            Text("Follow our channels:").foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                ForEach(About.channels, id: \.name) { Link($0.name, destination: $0.url) }
            }
            Divider().padding(.vertical, 4)
            Text(About.credit).font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Errors as an alert, not as menu text. One alert at a time: every stream can fail with the
/// same error at once. Shown on the next run-loop turn, so the caller finishes its clean-up first.
@MainActor
enum ErrorAlert {
    private static var showing = false

    static func show(_ title: String, _ message: String, fix: Permission? = nil) {
        let args = CommandLine.arguments
        if args.contains("--test") || args.contains("--test-play") {
            print("alert: \(title): \(message)")  // a modal alert would block a headless test
            return
        }
        guard !showing else { return }
        showing = true
        // Both cover every display above the alert, and a modal alert blocks their Esc key.
        GreenScreen.shared.hide()
        Playback.shared.stop()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = title
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                if fix != nil { alert.addButton(withTitle: "Open System Settings") }
                NSApp.activate()
                if alert.runModal() == .alertSecondButtonReturn { fix?.openSettings() }
                showing = false
            }
        }
    }
}

enum Permission: String, CaseIterable, Identifiable {
    case screen = "Screen Recording", camera = "Camera", microphone = "Microphone"
    var id: String { rawValue }

    /// true = allowed, false = denied, nil = not asked yet.
    var granted: Bool? {
        switch self {
        case .screen: CGPreflightScreenCaptureAccess() ? true : false
        case .camera: Self.status(.video)
        case .microphone: Self.status(.audio)
        }
    }

    @MainActor static var allGranted: Bool { allCases.allSatisfy { $0 == .camera && Recorder.shared.cameraID == nil || $0.granted == true } }

    func request() async {
        switch self {
        case .screen:
            if !CGRequestScreenCaptureAccess() { openSettings() }
        case .camera, .microphone:
            let type: AVMediaType = self == .camera ? .video : .audio
            if granted == nil { _ = await AVCaptureDevice.requestAccess(for: type) } else { openSettings() }
        }
    }

    func openSettings() {
        let anchor = switch self {
        case .screen: "Privacy_ScreenCapture"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    private static func status(_ type: AVMediaType) -> Bool? {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: true
        case .notDetermined: nil
        default: false
        }
    }
}

/// Ticks every 2 s while the Settings window is open, so permission rows re-read their status.
/// (An ObservableObject, not @State: SwiftUI's macros need Xcode, and we build with the CLT.)
private final class Ticker: ObservableObject {
    @Published var tick = 0
    private var timer: AnyCancellable?
    init() { timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick += 1 } }
}

private struct PermissionsTab: View {
    @StateObject private var ticker = Ticker()

    var body: some View {
        Form { permissions }.formStyle(.grouped)
    }

    private var permissions: some View {
        Section {
            let _ = ticker.tick
            ForEach(Permission.allCases) { p in
                let granted = p.granted
                LabeledContent {
                    if granted != true {
                        Button(granted == nil ? "Allow…" : "Open System Settings") { Task { await p.request() } }
                    }
                } label: {
                    Label {
                        Text(p.rawValue)
                    } icon: {
                        Image(systemName: granted == true ? "checkmark.circle.fill"
                              : granted == false ? "xmark.circle.fill" : "questionmark.circle")
                            .foregroundStyle(granted == true ? .green : granted == false ? .red : .secondary)
                    }
                }
            }
        } footer: {
            Text("After you allow Screen Recording, quit and reopen Screen It Recorder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
