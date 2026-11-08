import AppKit
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit

/// Plays videos full screen on the displays — a recording's screen files, or any file per display
/// (e.g. a recut export) — so a demo can be performed again live in front of the camera instead of
/// being keyed in later. Every display starts on the same host-clock instant. Beeps (a countdown,
/// a tick every N seconds, the last seconds, the end) tell the presenter where the video is
/// without a look at the screens. ⌃⌥P plays / pauses, ⌃⌥⇧P restarts, Esc stops.
@MainActor
final class Playback: ObservableObject {
    static let shared = Playback()

    enum State { case idle, countdown, playing, paused, ended }

    enum AtEnd: String, CaseIterable, Identifiable {
        case hold, restart
        var id: String { rawValue }
        var label: String { self == .hold ? "Hold the last frame" : "Restart (with the countdown)" }
    }

    static let countdowns = [0, 3, 5, 10]
    static let tickIntervals = [0, 5, 10, 15, 30, 60]
    static let lastSeconds = 5

    @Published private(set) var state = State.idle
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var countdownLeft = 0
    @Published private(set) var lastError: String?
    /// The video for each display, keyed by CGDirectDisplayID. A display without one stays visible.
    @Published private(set) var files: [UInt32: URL] = [:]
    /// Follow the newest recording until a folder or file is chosen.
    @Published private(set) var followsLatest = true
    @Published private(set) var sourceLabel = "No recording yet"

    @Published var countdown: Int { didSet { UserDefaults.standard.set(countdown, forKey: "playCountdown") } }
    @Published var tickEvery: Int { didSet { UserDefaults.standard.set(tickEvery, forKey: "playTickEvery") } }
    @Published var lastSecondBeeps: Bool {
        didSet { UserDefaults.standard.set(lastSecondBeeps, forKey: "playLastSeconds") }
    }
    @Published var atEnd: AtEnd { didSet { UserDefaults.standard.set(atEnd.rawValue, forKey: "playAtEnd") } }
    /// Off by default: a recording's own track is the mic from the first take.
    @Published var videoSound: Bool {
        didSet {
            UserDefaults.standard.set(videoSound, forKey: "playVideoSound")
            players.forEach { $0.isMuted = !videoSound }
        }
    }

    private var players: [AVPlayer] = []
    private var leader: AVPlayer?  // the longest video: drives the beeps and the end
    private var windows: [NSWindow] = []
    private var run: Task<Void, Never>?
    private var positionObserver: Any?
    private var beepObservers: [Any] = []
    private var endObserver: NSObjectProtocol?
    private var awake: NSObjectProtocol?
    private var starting = false  // a second ⌃⌥P while start() awaits must not start twice

    init() {
        let d = UserDefaults.standard
        countdown = d.object(forKey: "playCountdown") as? Int ?? 3
        tickEvery = d.object(forKey: "playTickEvery") as? Int ?? 10
        lastSecondBeeps = d.object(forKey: "playLastSeconds") as? Bool ?? true
        atEnd = d.string(forKey: "playAtEnd").flatMap(AtEnd.init) ?? .hold
        videoSound = d.object(forKey: "playVideoSound") as? Bool ?? false
    }

    var isActive: Bool { state != .idle }

    var status: String {
        let clock = "\(Self.clock(position)) / \(Self.clock(duration))"
        return switch state {
        case .idle: lastError.map { "Playback: \($0)" } ?? "Playback: \(sourceLabel)"
        case .countdown: countdownLeft > 0 ? "Playback starts in \(countdownLeft)…" : "Playback starting…"
        case .playing: "▶ Playing \(clock)"
        case .paused: "❚❚ Paused \(clock)"
        case .ended: "■ Ended \(clock)"
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - What to play

    /// Each recording names its files screen0.mov, screen1.mov… in ScreenCaptureKit's display
    /// order (see Recorder.start), so the same order puts each file back on its own display.
    func useLatest() async {
        followsLatest = true
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Recorder.shared.folder, includingPropertiesForKeys: nil)) ?? []
        // Any screen file: a recording of one display has only that display's screen<i>.mov.
        let newest = dirs.filter { dir in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
            return names.contains { $0.hasPrefix("screen") && $0.hasSuffix(".mov") }
        }
            .max { $0.lastPathComponent < $1.lastPathComponent }  // folder names are sortable timestamps
        guard let newest else {
            files = [:]
            sourceLabel = "No recording yet"
            return
        }
        await load(folder: newest)
        sourceLabel = "Latest recording (\(newest.lastPathComponent))"
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a recording to play"
        panel.prompt = "Play This"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Recorder.shared.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await use(folder: url) }
    }

    func use(folder: URL) async {
        followsLatest = false
        await load(folder: folder)
        sourceLabel = files.isEmpty ? "No screen files in \(folder.lastPathComponent)" : folder.lastPathComponent
    }

    func chooseFile(for display: UInt32) {
        let panel = NSOpenPanel()
        panel.title = "Choose a video for this display"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.movie]
        panel.directoryURL = files[display]?.deletingLastPathComponent() ?? Recorder.shared.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        followsLatest = false
        files[display] = url
        sourceLabel = "Chosen files"
    }

    func clear(_ display: UInt32) {
        followsLatest = false
        files[display] = nil
        sourceLabel = "Chosen files"
    }

    private func load(folder: URL) async {
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ids = content?.displays.map(\.displayID) ?? NSScreen.screens.compactMap(Backlight.displayID)
        var found: [UInt32: URL] = [:]
        for (i, id) in ids.enumerated() {
            let url = folder.appending(path: "screen\(i).mov")
            if FileManager.default.fileExists(atPath: url.path) { found[id] = url }
        }
        files = found
    }

    // MARK: - Controls

    /// ⌃⌥P: start, pause, resume, or play an ended video again.
    func togglePlay() {
        switch state {
        case .idle: Task { await start() }
        case .playing, .countdown: pause()
        case .paused: run = Task { await countdownThenPlay() }
        case .ended: restart()
        }
    }

    func start() async {
        guard state == .idle, !starting else { return }
        starting = true
        defer { starting = false }
        if followsLatest { await useLatest() }
        let screens = NSScreen.screens
        let targets = files.compactMap { id, url in
            screens.first { Backlight.displayID($0) == id }.map { ($0, url) }
        }
        guard !targets.isEmpty else {
            lastError = files.isEmpty ? "nothing to play" : "displays not connected"
            PlaybackPanel.show()
            ErrorAlert.show("Nothing to play", files.isEmpty
                ? "There is no recording yet. Choose a recording folder or a video in the Playback window."
                : "The displays for the chosen videos are not connected. Choose a video for a connected display.")
            return
        }
        lastError = nil
        GreenScreen.shared.hide()

        for (screen, url) in targets {
            let player = AVPlayer(url: url)
            player.automaticallyWaitsToMinimizeStalling = false  // required by setRate(_:time:atHostTime:)
            player.actionAtItemEnd = .pause
            player.isMuted = !videoSound
            players.append(player)
            windows.append(PlayerWindow(screen: screen, player: player))
        }
        state = .countdown
        NSApp.activate()
        windows.first?.makeKey()
        NSCursor.hide()
        awake = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing a demo")

        do {
            var longest = 0.0
            for (player, (_, url)) in zip(players, targets) {
                guard let item = player.currentItem else { continue }
                // Poll, with a limit: an async KVO stream on `status` never delivered here (2026-10-11).
                for _ in 0..<500 where item.status == .unknown { try await Task.sleep(for: .milliseconds(20)) }
                if let error = item.error { throw error }
                guard item.status == .readyToPlay else { throw RecError("\(url.lastPathComponent) did not load") }
                let seconds = try await item.asset.load(.duration).seconds
                if seconds > longest || leader == nil { longest = seconds; leader = player }
            }
            duration = longest
        } catch {
            lastError = "could not start"
            stop()
            ErrorAlert.show("Playback could not start", error.localizedDescription)
            return
        }
        guard state != .idle, let leader else { return }  // stopped while loading

        positionObserver = leader.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.position = time.seconds }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: leader.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        }
        run = Task { await countdownThenPlay() }
    }

    func pause() {
        guard state == .playing || state == .countdown else { return }
        run?.cancel()
        players.forEach { $0.pause() }
        countdownLeft = 0
        state = .paused
    }

    /// ⌃⌥⇧P: from the first frame again, after the countdown.
    func restart() {
        guard state != .idle else { Task { await start() }; return }
        run?.cancel()
        players.forEach { $0.pause() }
        run = Task {
            for player in players { await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
            position = 0
            await countdownThenPlay()
        }
    }

    func stop() {
        guard state != .idle else { return }
        run?.cancel()
        run = nil
        removeBeeps()
        if let positionObserver { leader?.removeTimeObserver(positionObserver) }
        positionObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        players.forEach { $0.pause() }
        players.removeAll()
        leader = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.unhide()
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        countdownLeft = 0
        position = 0
        state = .idle
    }

    var leaderTime: Double { leader?.currentTime().seconds ?? 0 }

    /// The largest gap between the displays' current frames, in seconds (for `--test-play`).
    var spread: Double {
        let times = players.map { $0.currentTime().seconds }
        return (times.max() ?? 0) - (times.min() ?? 0)
    }

    // MARK: - Internals

    private func countdownThenPlay(after delay: Double = 0) async {
        state = .countdown
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        for n in stride(from: countdown, to: 0, by: -1) {
            guard !Task.isCancelled else { return }
            countdownLeft = n
            Beep.play(Beep.count)
            try? await Task.sleep(for: .seconds(1))
        }
        guard !Task.isCancelled, let leader else { return }
        countdownLeft = 0
        if countdown > 0 { Beep.play(Beep.go) }

        planBeeps()
        // Every display from the leader's frame, on one host-clock instant, so they stay frame-locked.
        let from = leader.currentTime()
        let at = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 1, timescale: 10)
        for player in players { player.setRate(1, time: from, atHostTime: at) }
        state = .playing
    }

    /// A tick every `tickEvery` seconds, and a count beep in each of the last seconds. Boundary
    /// observers follow the video's own time, so a pause also pauses the beeps.
    private func planBeeps() {
        removeBeeps()
        guard let leader, duration > 1 else { return }
        var last: [Double] = []
        if lastSecondBeeps {
            last = (1...Self.lastSeconds).map { duration - Double($0) }.filter { $0 > 0 }
        }
        var ticks: [Double] = []
        if tickEvery > 0 {
            ticks = stride(from: Double(tickEvery), to: duration, by: Double(tickEvery))
                .filter { t in !last.contains { abs($0 - t) < 0.5 } }
        }
        for (times, sound) in [(ticks, Beep.tick), (last, Beep.count)] where !times.isEmpty {
            let values = times.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
            beepObservers.append(leader.addBoundaryTimeObserver(forTimes: values, queue: .main) {
                MainActor.assumeIsolated { Beep.play(sound) }
            })
        }
    }

    private func removeBeeps() {
        beepObservers.forEach { leader?.removeTimeObserver($0) }
        beepObservers.removeAll()
    }

    private func ended() {
        guard state == .playing else { return }
        Beep.play(Beep.end)
        position = duration
        if atEnd == .restart {
            run = Task {
                for player in players { await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
                await countdownThenPlay(after: 1.5)  // let the end sound finish first
            }
        } else {
            state = .ended
        }
    }
}

/// macOS system sounds (/System/Library/Sounds) — distinct enough to tell apart without a look.
@MainActor
private enum Beep {
    static let count = "Pop", go = "Glass", tick = "Tink", end = "Hero"

    static func play(_ name: String) {
        if CommandLine.arguments.contains("--test-play") {
            print("beep \(name) at video \(Playback.clock(Playback.shared.leaderTime))")
        }
        guard let sound = NSSound(named: name) else { return }
        sound.stop()  // one shared instance per name: restart it if it is still playing
        sound.play()
    }
}

/// A borderless window over one display that shows one player, black around the video.
private final class PlayerWindow: NSWindow {
    init(screen: NSScreen, player: AVPlayer) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver  // above the menu bar and the Dock, as the green screen
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        let view = NSView()
        view.layer = layer  // layer-hosting: set the layer before wantsLayer
        view.wantsLayer = true
        contentView = view
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: Playback.shared.stop()
        case kVK_Space: Playback.shared.togglePlay()
        default: super.keyDown(with: event)
        }
    }
}
