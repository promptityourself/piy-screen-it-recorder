import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct ScreenItRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var rec = Recorder.shared
    @StateObject private var green = GreenScreen.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(rec).environmentObject(green)
        } label: {
            Image(nsImage: Logo.menuBar(recording: rec.isRecording))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        _ = MainActor.assumeIsolated { ClickHighlight.shared }  // follows the recording from now on
        HotKey.register(keyCode: kVK_ANSI_G, modifiers: controlKey | optionKey) {
            Task { @MainActor in GreenScreen.shared.toggle() }
        }
        // ⌃⌥R is FCP's Retime → Custom Speed; ⌃⌥⇧R is free there.
        HotKey.register(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey | shiftKey) {
            Task { @MainActor in await Recorder.shared.userToggle() }
        }

        // ⌃⌥P / ⌃⌥⇧P are free in FCP's Default.commandset (checked 2026-10-11).
        HotKey.register(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey) {
            Task { @MainActor in Playback.shared.togglePlay() }
        }
        HotKey.register(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey | shiftKey) {
            Task { @MainActor in Playback.shared.restart() }
        }

        // `--settings [recording|sound|tags|colour|shortcuts|permissions]`, `--about`, `--playback`,
        // `--select-area`, `--setup` (the setup bar): open that window.
        let launch = CommandLine.arguments
        if let i = launch.firstIndex(of: "--settings") {
            let tabs: [String: SettingsWindow.Tab] = [
                "recording": .recording, "sound": .sound, "tags": .tags, "colour": .colour, "shortcuts": .shortcuts, "permissions": .permissions,
            ]
            let tab = i + 1 < launch.count ? tabs[launch[i + 1]] : nil
            MainActor.assumeIsolated { SettingsWindow.show(tab) }
        }
        if launch.contains("--about") { MainActor.assumeIsolated { About.show() } }
        if launch.contains("--select-area") { MainActor.assumeIsolated { AreaPicker.show() } }
        if launch.contains("--setup") { MainActor.assumeIsolated { AreaPicker.show(.setup) } }
        // `--setup --new-tag`: the setup bar with its "new tag" field open (a visual check).
        if launch.contains("--new-tag") {
            MainActor.assumeIsolated {
                Tags.shared.adding = true
                SetupBar.focus()
            }
        }
        if CommandLine.arguments.contains("--playback") { MainActor.assumeIsolated { PlaybackPanel.show() } }

        // `--test <seconds> [--green] [--clicks]`: record (optionally over green, with a click ripple
        // in the centre of each display after 1 s), stop, quit — a headless smoke test.
        let args = CommandLine.arguments

        // `--test-play <seconds> [folder]`: play the latest recording (or that folder) with the saved playback settings,
        // print how far apart the displays' frames are, stop, quit.
        if let i = args.firstIndex(of: "--test-play"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            setvbuf(stdout, nil, _IOLBF, 0)  // a killed test still shows how far it got
            // Watchdog: a hung test must never leave the displays covered.
            DispatchQueue.main.asyncAfter(deadline: .now() + secs + 20) { print("watchdog: test hung"); exit(2) }
            Task { @MainActor in
                let play = Playback.shared
                if i + 2 < args.count, !args[i + 2].hasPrefix("-") {
                    await play.use(folder: URL(filePath: args[i + 2], directoryHint: .isDirectory))
                }
                await play.start()
                guard play.isActive else { print(play.status); exit(1) }
                let end = ContinuousClock.now + .seconds(secs)
                while ContinuousClock.now < end {
                    try? await Task.sleep(for: .seconds(1))
                    print(play.status, String(format: "spread %.3fs", play.spread))
                }
                play.stop()
                exit(0)
            }
        }
        if let i = args.firstIndex(of: "--test"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            Task { @MainActor in
                let rec = Recorder.shared
                if args.contains("--green") { GreenScreen.shared.show() }
                await rec.start()
                print(rec.status)
                // `--retag <a,b>`: set these active tags half-way, as a change during a recording.
                if let r = args.firstIndex(of: "--retag"), r + 1 < args.count {
                    try? await Task.sleep(for: .seconds(secs / 2))
                    let wanted = args[r + 1].split(separator: ",").map(String.init)
                    for tag in Tags.shared.known where !wanted.contains(tag) { Tags.shared.set(tag, false) }
                    wanted.forEach { Tags.shared.add($0) }
                    try? await Task.sleep(for: .seconds(secs / 2))
                    await rec.stop()
                    print(rec.status)
                    exit(rec.lastError == nil ? 0 : 1)
                }
                if args.contains("--clicks") {
                    try? await Task.sleep(for: .seconds(1))
                    for s in NSScreen.screens { ClickHighlight.shared.ripple(at: NSPoint(x: s.frame.midX, y: s.frame.midY)) }
                    try? await Task.sleep(for: .seconds(max(0, secs - 1)))
                } else {
                    try? await Task.sleep(for: .seconds(secs))
                }
                await rec.stop()
                GreenScreen.shared.hide()
                print(rec.status)
                exit(rec.lastError == nil ? 0 : 1)
            }
        }
    }

    // Quitting (or logging out) mid-recording finalises the files first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Recorder.shared.isRecording else { return .terminateNow }
        Task { @MainActor in
            await Recorder.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Never leave the displays dimmed by the green screen.
    func applicationWillTerminate(_ note: Notification) {
        MainActor.assumeIsolated {
            GreenScreen.shared.hide()
            Playback.shared.stop()
        }
    }
}

/// Record → All displays, or a display in full / left half / right half / the selected area.
struct AreaMenu: View {
    @ObservedObject private var area = RecordArea.shared

    var body: some View {
        Menu("Record: \(area.summary)") {
            Toggle("All Displays", isOn: choice(nil, .full))
            ForEach(RecordArea.displays(), id: \.uuid) { d in
                Section(d.name) {
                    ForEach([RecordArea.Preset.full, .left, .right]) { p in
                        Toggle(p.label, isOn: choice(d.uuid, p))
                    }
                    if area.display == d.uuid, area.preset == .custom {
                        Toggle(RecordArea.Preset.custom.label, isOn: choice(d.uuid, .custom))
                    }
                }
            }
            Divider()
            Button("Select Area…") { AreaPicker.show() }
        }
    }

    private func choice(_ uuid: String?, _ preset: RecordArea.Preset) -> Binding<Bool> {
        Binding(get: { area.display == uuid && (uuid == nil || area.preset == preset) },
                set: { if $0 { area.choose(display: uuid, preset) } })
    }
}

/// A tick box per tag, and New Tag…: the setup bar and the menu bar menu.
struct TagItems: View {
    @ObservedObject private var tags = Tags.shared
    let newTag: () -> Void

    var body: some View {
        ForEach(tags.known, id: \.self) { tag in
            Toggle(tag, isOn: Binding(get: { tags.isOn(tag) }, set: { tags.set(tag, $0) }))
        }
        if !tags.known.isEmpty { Divider() }
        Button("New Tag…", action: newTag)
    }
}

struct MenuView: View {
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var green: GreenScreen
    @ObservedObject private var play = Playback.shared
    @ObservedObject private var tags = Tags.shared

    var body: some View {
        Text(rec.status)
        if !Permission.allGranted {
            Button("⚠︎ Permissions Needed…") { SettingsWindow.show(.permissions) }
        }
        Button(rec.isRecording ? "Stop Recording (⌃⌥⇧R)" : rec.setupBar ? "Start Recording… (⌃⌥⇧R)" : "Start Recording (⌃⌥⇧R)") {
            Task { await rec.userToggle() }
        }
        AreaMenu().disabled(rec.isRecording)
        // Also during a recording: a change goes into its recording.json at once.
        Menu("Tags: \(tags.summary)") { TagItems { SettingsWindow.show(.tags) } }
        Button(green.isOn ? "\(green.shade.family) Screen Off (⌃⌥G / Esc)" : "\(green.shade.family) Screen On (⌃⌥G)") {
            green.toggle()
        }
        Divider()
        if play.isActive {
            Text(play.status)
            Button(play.state == .paused || play.state == .ended ? "Resume Playback (⌃⌥P)" : "Pause Playback (⌃⌥P)") {
                play.togglePlay()
            }
            Button("Restart Playback (⌃⌥⇧P)") { play.restart() }
            Button("Stop Playback (Esc)") { play.stop() }
        } else {
            Button(play.followsLatest ? "Play Latest Recording (⌃⌥P)" : "Play Chosen Videos (⌃⌥P)") { play.togglePlay() }
        }
        Button("Playback…") { PlaybackPanel.show() }
        Divider()
        Button("About Screen It Recorder") { About.show() }
        Button("Settings…") { SettingsWindow.show() }
            .keyboardShortcut(",")
        Button("Open Recordings Folder") { rec.openFolder() }
        Divider()
        Button("Quit Screen It Recorder") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
