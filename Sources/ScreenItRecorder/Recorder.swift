import AppKit
import AVFoundation
import os
import ScreenCaptureKit

/// Records every display to its own .mov (HEVC, ~1440p, 30fps). Each file carries the
/// same microphone track, so FCP's "Synchronize Clips" (or a clap) lines them up.
@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    static let targetWidth = 2560
    nonisolated static let fps: Int32 = 30
    /// Refuse to start with less room than this, or than 15 minutes at the chosen quality.
    static let minFreeBytes: Int64 = 10_000_000_000
    static let stampFormat = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"  // local time, matches the `rec` script
        return f
    }()

    @Published private(set) var isRecording = false
    @Published private(set) var status = "Ready"
    @Published private(set) var lastError: String?
    /// nil = no microphone. Stored as "" so "None" survives a restart; a missing key means
    /// never chosen, and then the system default mic is used.
    @Published var micID: String? {
        didSet { UserDefaults.standard.set(micID ?? "", forKey: "micID") }
    }
    @Published var cameraID: String? {
        didSet { UserDefaults.standard.set(cameraID, forKey: "cameraID") }
    }
    @Published var cameraFPS: Int {
        didSet { UserDefaults.standard.set(cameraFPS, forKey: "cameraFPS") }
    }
    /// Seconds of count beeps after the start, then a "go" tone; 0 = none. See Countdown.
    @Published var startCountdown: Int {
        didSet { UserDefaults.standard.set(startCountdown, forKey: "startCountdown") }
    }
    /// Record the apps' sound as a second track in each screen file.
    @Published var appSound: Bool {
        didSet { UserDefaults.standard.set(appSound, forKey: "appSound") }
    }
    nonisolated static let appSoundRate = 48_000
    private var countdown: Task<Void, Never>?
    @Published var hideWidgets: Bool {
        didSet { UserDefaults.standard.set(hideWidgets, forKey: "hideWidgets") }
    }
    @Published var quality: Quality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "recQuality") }
    }
    @Published var codec: Codec {
        didSet { UserDefaults.standard.set(codec.rawValue, forKey: "recCodec") }
    }
    @Published var resolution: Resolution {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "recResolution") }
    }

    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Movies/ScreenItRecorder", directoryHint: .isDirectory)
    /// Where each session's folder goes. Chosen in Settings; nil in the prefs = the default.
    @Published var folder: URL {
        didSet {
            UserDefaults.standard.set(isDefaultFolder ? nil : folder.path(percentEncoded: false), forKey: "saveFolder")
        }
    }

    private var streams: [SCStream] = []
    private var started: [SCStream] = []
    private var camera: CameraRecorder?
    private var pendingFinishes: [CheckedContinuation<Void, Never>] = []
    private var unfinished = 0
    private var awake: NSObjectProtocol?
    private var widgetsWereHidden: Bool?
    private var session: String?  // the folder name of the current recording
    /// A start or stop is in progress. A camera can take seconds to warm up, and a second ⌃⌥⇧R
    /// meanwhile must not begin a second recording.
    private var busy = false
    /// How long stop() waits for the camera's "finished" callback before it checks the file itself.
    static let saveTimeout: Duration = .seconds(10)
    nonisolated static let log = Logger(subsystem: "com.mergodon.ScreenItRecorder", category: "recorder")
    private var writers: [ScreenWriter] = []  // same order as `streams`
    /// Streams that already stopped (Stop in the macOS menu bar, an error). Stopping one again
    /// took ~35 s to return (2026-10-11), so stop() skips them.
    private var stoppedStreams: Set<ObjectIdentifier> = []
    private var cameraFile: URL?
    private var watchdog: Task<Void, Never>?
    private var deviceObservers: [NSObjectProtocol] = []

    /// Every recorded display (or part of one) together, at the measured rate of the chosen settings.
    var bytesPerSecond: Double {
        let area = RecordArea.shared
        let displays = area.display == nil ? Double(max(1, NSScreen.screens.count)) : area.fraction
        return MeasuredRate.mbps(codec, resolution, quality) * 1_000_000 / 8 * displays
    }

    private var isDefaultFolder: Bool { folder.standardizedFileURL == Self.defaultFolder.standardizedFileURL }

    var mics: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }

    override init() {
        let d = UserDefaults.standard
        hideWidgets = d.object(forKey: "hideWidgets") as? Bool ?? true
        startCountdown = d.object(forKey: "startCountdown") as? Int ?? 3
        appSound = d.object(forKey: "appSound") as? Bool ?? true
        micID = d.string(forKey: "micID").map { $0.isEmpty ? nil : $0 }
            ?? AVCaptureDevice.default(for: .audio)?.uniqueID
        cameraID = d.string(forKey: "cameraID")  // off unless chosen
        folder = d.string(forKey: "saveFolder").map { URL(filePath: $0, directoryHint: .isDirectory) } ?? Self.defaultFolder
        cameraFPS = d.object(forKey: "cameraFPS") as? Int ?? Int(Self.fps)  // match the screens
        quality = d.string(forKey: "recQuality").flatMap(Quality.init) ?? .high
        codec = d.string(forKey: "recCodec").flatMap(Codec.init) ?? .hevc
        resolution = d.string(forKey: "recResolution").flatMap(Resolution.init) ?? .p1440
        super.init()
        // A mic or camera plugged in (or out) while Settings is open shows up in its pickers at once.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Recorder.shared.objectWillChange.send() }
            })
        }
    }

    func start() async {
        guard !isRecording, !busy else { return }
        busy = true
        defer { busy = false }
        lastError = nil
        unfinished = 0
        do {
            // An ad-hoc build is a new app to macOS after every rebuild, so this is the usual failure.
            guard CGPreflightScreenCaptureAccess() else {
                CGRequestScreenCaptureAccess()
                throw RecError("Allow Screen It Recorder in System Settings → Privacy & Security → "
                    + "Screen & System Audio Recording, then quit and reopen it")
            }
            // Create only the default folder. A chosen folder that is missing is usually a drive
            // that is not connected; creating it would record onto the internal disk instead.
            if isDefaultFolder {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } else if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
                throw RecError("The save folder \(folder.path(percentEncoded: false)) is not there. "
                    + "Connect its drive, or choose another folder in Settings → Recording.")
            }
            // On an SMB share both URL capacity keys come back 0/nil (measured on the fleet share);
            // statfs (via attributesOfFileSystem) reports the real figure there.
            let space = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            var free = space.volumeAvailableCapacityForImportantUsage ?? 0
            if free == 0, let fs = try? FileManager.default.attributesOfFileSystem(forPath: folder.path(percentEncoded: false)),
               let n = fs[.systemFreeSize] as? NSNumber {
                free = n.int64Value
            }
            let need = max(Self.minFreeBytes, Int64(bytesPerSecond * 15 * 60))
            guard free >= need else {
                throw RecError("Only \(free / 1_000_000_000) GB free. The chosen quality needs at least "
                    + "\(need / 1_000_000_000) GB (15 minutes). Free some space, or lower the quality in Settings.")
            }

            let stamp = Self.stampFormat.string(from: .now)
            let dir = folder.appending(path: stamp, directoryHint: .isDirectory)

            if let micID {
                guard mics.contains(where: { $0.uniqueID == micID }) else {
                    throw RecError("The chosen microphone is not connected. Connect it, or choose another one "
                        + "in Settings → Recording.")
                }
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw RecError("Screen It Recorder has no permission to use the microphone.")
                }
            }

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !content.displays.isEmpty else { throw RecError("No displays found") }
            if let cameraID {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    throw RecError("Screen It Recorder has no permission to use the camera.")
                }
                camera = try CameraRecorder(cameraID: cameraID, micID: micID, fps: Int32(cameraFPS))
            }

            if hideWidgets {
                widgetsWereHidden = Widgets.hidden
                Widgets.hidden = true
            }
            awake = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Recording screens")

            // screen<i> keeps the display's place in ScreenCaptureKit's order even when only one
            // display records, so Playback puts the file back on that display.
            let area = RecordArea.shared
            var displays = Array(content.displays.enumerated())
            if let uuid = area.display {
                displays = displays.filter { RecordArea.uuid($0.element.displayID) == uuid }
                guard !displays.isEmpty else {
                    throw RecError("The display chosen for the recording area is not connected. Choose "
                        + "another one in the menu → Record.")
                }
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, display) in displays {
                let unit = area.display == nil ? nil : area.unitRect
                try makeStream(display: display, area: unit, url: dir.appending(path: "screen\(i).mov"))
            }
            if let camera {
                status = "Starting camera…"
                unfinished += 1
                let url = dir.appending(path: "camera.mov")
                cameraFile = url
                await camera.start(to: url) { error in
                    Task { @MainActor in
                        if let error { self.fail(error) }
                        self.finishedOne()
                    }
                }
            }
            for stream in streams {
                try await stream.startCapture()
                started.append(stream)
            }

            isRecording = true
            watchForSystemStop()
            session = stamp
            let what = area.display == nil ? "\(streams.count) screens" : area.summary
            let recording = "● Recording \(what)\(camera == nil ? "" : " + camera")"
            status = recording
            if startCountdown > 0 {
                let seconds = startCountdown
                countdown = Task {
                    await Countdown.run(seconds) { left in
                        guard self.isRecording else { return }
                        self.status = left > 0 ? "● Recording — start talking after the go tone: \(left)" : recording
                    }
                }
            }
        } catch {
            camera?.stop()
            for stream in started { try? await stream.stopCapture() }
            await teardown()
            fail(error)
        }
    }

    func stop() async {
        guard isRecording, !busy else { return }
        busy = true
        defer { busy = false }
        countdown?.cancel()
        countdown = nil
        status = "Saving…"
        camera?.stop()
        for stream in streams where !stoppedStreams.contains(ObjectIdentifier(stream)) {
            try? await stream.stopCapture()
        }
        for writer in writers {
            do { try await writer.finish() } catch { fail(error) }
        }
        if unfinished > 0 {
            // Never wait forever for the camera's "finished" callback — that blocks the next
            // recording and Quit — and judge the file itself, not the missing callback.
            let timeout = Task {
                try? await Task.sleep(for: Self.saveTimeout)
                guard !Task.isCancelled, unfinished > 0 else { return }
                let bad = await Self.unreadable(cameraFile.map { [$0] } ?? [])
                Self.log.notice("no finish callback for \(self.unfinished) file(s); unreadable: \(bad.count)")
                if !bad.isEmpty {
                    fail(RecError("\(bad.joined(separator: ", ")) did not finish saving and can be incomplete."))
                }
                unfinished = 1
                finishedOne()
            }
            await withCheckedContinuation { pendingFinishes.append($0) }
            timeout.cancel()
        }
        await teardown()
        if lastError == nil { status = "Saved: \(session ?? "")" }
    }

    func openFolder() {
        if isDefaultFolder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        NSWorkspace.shared.open(folder)
    }

    /// `area`: the part of the display to record, as fractions of it (origin top left); nil = all of it.
    private func makeStream(display: SCDisplay, area: CGRect?, url: URL) throws {
        let crop = area.map { RecordArea.scale($0, to: CGSize(width: display.width, height: display.height)).integral }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        // Native = every physical pixel (5120×2880 on a Studio Display); 1440p = 2560 wide.
        let native = Int((Double(display.width) * Double(filter.pointPixelScale)).rounded())
        let fullWidth = resolution == .native ? native : min(Self.targetWidth, native)
        // A crop keeps the pixel density of the whole display: half a display is half as wide.
        let perPoint = Double(fullWidth) / Double(display.width)
        let source = crop ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
        if let crop { cfg.sourceRect = crop }
        cfg.width = Int((source.width * perPoint).rounded()) & ~1
        cfg.height = Int((source.height * perPoint).rounded()) & ~1
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: Self.fps)
        cfg.showsCursor = true
        // Capture in sRGB, not the display's P3, so pixels match the file's BT.709 tag
        // (and the green screen lands as exact #00FF00).
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.queueDepth = 8
        cfg.streamName = "Screen It Recorder"
        let mic = micID.flatMap { AVCaptureDevice(uniqueID: $0) }
        if let micID {
            cfg.captureMicrophone = true
            cfg.microphoneCaptureDeviceID = micID
        }
        if appSound {
            cfg.capturesAudio = true
            // Our own count beeps too: digital and at full level here, an exact marker in every
            // screen file (the mic hears them only faintly from the speakers).
            cfg.excludesCurrentProcessAudio = false
            cfg.sampleRate = Self.appSoundRate
            cfg.channelCount = 2
        }

        let writer = try ScreenWriter(url: url, width: cfg.width, height: cfg.height, codec: codec,
                                      quality: quality, mic: mic, appSound: appSound, area: area) { error in
            Task { @MainActor in self.fail(error) }
        }
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if mic != nil { try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue) }
        if appSound { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
        streams.append(stream)
        writers.append(writer)
    }

    private func teardown() async {
        watchdog?.cancel()
        watchdog = nil
        writers.removeAll()
        stoppedStreams.removeAll()
        cameraFile = nil
        streams.removeAll()
        started.removeAll()
        camera = nil
        unfinished = 0
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        if let was = widgetsWereHidden { Widgets.hidden = was }
        widgetsWereHidden = nil
        isRecording = false
    }

    /// Backup for a recording that ends outside the app with no callback: when no stream has
    /// delivered anything for 6 s, save and stop. A still screen still delivers idle frames, and
    /// the mic delivers audio all the time.
    private func watchForSystemStop() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isRecording, !self.busy else { return }
                if !self.writers.isEmpty, self.writers.allSatisfy({ $0.silence > .seconds(6) }) {
                    Self.log.notice("no samples for 6 s: stopped outside the app")
                    await self.stop()
                    return
                }
            }
        }
    }

    /// Names of the files that do not open as a movie with a duration.
    private static func unreadable(_ urls: [URL]) async -> [String] {
        var bad: [String] = []
        for url in urls {
            let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
            if !(seconds.map { $0 > 0 } ?? false) { bad.append(url.lastPathComponent) }
        }
        return bad
    }

    private func finishedOne() {
        unfinished -= 1
        guard unfinished <= 0 else { return }
        pendingFinishes.forEach { $0.resume() }
        pendingFinishes.removeAll()
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        status = isRecording ? "● Recording, with an error" : "Recording failed"
        // Offer the System Settings pane when a missing permission is the likely cause.
        let fix: Permission? = !CGPreflightScreenCaptureAccess() ? .screen
            : cameraID != nil && Permission.camera.granted != true ? .camera
            : micID != nil && Permission.microphone.granted != true ? .microphone : nil
        ErrorAlert.show("Recording failed", error.localizedDescription, fix: fix)
    }
}

extension Recorder: SCStreamDelegate {
    /// Also called when Stop is chosen in the macOS screen-recording menu in the menu bar (one
    /// Stop per display): stop the whole recording, as a normal stop, not a failure.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        Self.log.notice("stream stopped, code \(code): \(error.localizedDescription, privacy: .public)")
        let id = ObjectIdentifier(stream)
        Task { @MainActor in
            self.stoppedStreams.insert(id)
            if code != SCStreamError.Code.userStopped.rawValue { self.fail(error) }
            await self.stop()
        }
    }
}

struct RecError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// System Settings → Desktop & Dock → Show Widgets → On Desktop. Takes effect live.
enum Widgets {
    static var hidden: Bool {
        get { defaults(["read", "com.apple.WindowManager", "StandardHideWidgets"]) == "1" }
        set { _ = defaults(["write", "com.apple.WindowManager", "StandardHideWidgets", "-bool", newValue ? "true" : "false"]) }
    }

    private static func defaults(_ args: [String]) -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(filePath: "/usr/bin/defaults")
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
