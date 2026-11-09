import AppKit
import Foundation

/// What a recording is about, as short names (`short-cv-search`, `c001-fundamentals`). The active
/// tags stay on from one recording to the next, and can change during a recording: Recorder
/// writes them to recording.json and to the Finder tags of the folder and its files.
@MainActor
final class Tags: ObservableObject {
    static let shared = Tags()

    /// Every tag you made, in the order you made them.
    @Published private(set) var known: [String] {
        didSet { UserDefaults.standard.set(known, forKey: "tags") }
    }
    /// The tags of the next (or the current) recording; always a subset of `known`.
    @Published var active: [String] {
        didSet { UserDefaults.standard.set(active, forKey: "activeTags") }
    }
    /// Settings' "new tag" field (no @State without Xcode's macros).
    @Published var draft = ""
    /// The setup bar shows its own "new tag" field instead of the tag pop-up. A separate window
    /// would go under the bar's cover, where no click reaches it.
    @Published var adding = false
    @Published var barDraft = ""

    private init() {
        let d = UserDefaults.standard
        known = d.stringArray(forKey: "tags") ?? []
        active = d.stringArray(forKey: "activeTags") ?? []
    }

    /// The setup bar and the menu: "No tag", the tag, or "short-cv-search +1".
    var summary: String {
        switch active.count {
        case 0: "No tag"
        case 1: active[0]
        case let n: "\(active[0]) +\(n - 1)"
        }
    }

    func isOn(_ tag: String) -> Bool { active.contains(tag) }

    func set(_ tag: String, _ on: Bool) {
        active.removeAll { $0 == tag }
        // Keep the order of `known`, so the same tags always read the same.
        if on { active = known.filter { $0 == tag || active.contains($0) } }
    }

    /// Adds a tag (or finds the one with the same name in any case) and turns it on.
    /// Returns false for an empty name.
    @discardableResult
    func add(_ name: String) -> Bool {
        let tag = Self.clean(name)
        guard !tag.isEmpty else { return false }
        let existing = known.first { $0.caseInsensitiveCompare(tag) == .orderedSame }
        if existing == nil { known.append(tag) }
        set(existing ?? tag, true)
        return true
    }

    func remove(_ tag: String) {
        active.removeAll { $0 == tag }
        known.removeAll { $0 == tag }
    }

    /// One line, spaces collapsed: a Finder tag and a JSON string need nothing more.
    static func clean(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// recording.json: what a recording folder holds and what it is about, for whoever (or whatever
/// agent) reviews or cuts it. Written when the recording starts, again when the tags change, and
/// last at Stop, so a crash still leaves one.
struct RecordingInfo: Encodable {
    struct File: Encodable {
        var file: String
        /// screen, mic, app-sound or camera.
        var kind: String
        /// The display, the mic or camera device, or the app.
        var source: String
        var bundleID: String?
        var width: Int?
        var height: Int?
        var fps: Int?
        var codec: String?
        /// The recorded part of the display: x, y, width, height as fractions of it, origin top
        /// left. Absent for a whole display.
        var area: [Double]?
    }

    var format = 1
    var app: String
    var macOS: String
    var tags: [String]
    var started: String
    var ended: String?
    var seconds: Double?
    /// Seconds of count beeps (880 Hz) before the "go" tone (1760 Hz); 0 = no countdown. The
    /// screen files carry the tones as their only audio track.
    var countdown: Int
    var files: [File]

    static let name = "recording.json"

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Screen It Recorder \(version) (\(build))"
    }()

    /// Local time with its offset: the folder name is local time too.
    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Writes recording.json into `dir`, and sets the tags as Finder tags on the folder and on
    /// the files that are there (`files: true`; at Stop, when the writers are done with them).
    func save(in dir: URL, files: Bool) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: dir.appending(path: Self.name), options: .atomic)
        var urls = [dir]
        if files { urls += self.files.map { dir.appending(path: $0.file) } + [dir.appending(path: Self.name)] }
        for url in urls where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            // URLResourceValues.tagNames is read-only; NSURL can write it.
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
    }
}
