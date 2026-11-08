import AppKit

/// The start countdown: the recording runs from the first beep, so the mic records the count
/// beeps and the "go" tone, and the cut (by hand or by an agent) starts at "go". Pure sine tones,
/// so an agent can find them by frequency: each count is 880 Hz for 0.12 s, "go" is 1760 Hz for 0.4 s.
@MainActor
enum Countdown {
    static let choices = [0, 3, 5, 10]
    static let countHz = 880.0, countSeconds = 0.12
    static let goHz = 1760.0, goSeconds = 0.4

    private static let count = tone(hz: countHz, seconds: countSeconds)
    private static let go = tone(hz: goHz, seconds: goSeconds)

    /// Beeps once a second for `seconds` seconds, then "go". `tick` gets the seconds left
    /// (0 = go). Returns early when the task is cancelled (the recording stopped).
    static func run(_ seconds: Int, tick: (Int) -> Void) async {
        for left in stride(from: seconds, to: 0, by: -1) {
            tick(left)
            play(count)
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
        tick(0)
        play(go)
    }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }

    /// A sine tone as an in-memory 16-bit mono WAV, with 5 ms fades so it does not click.
    private static func tone(hz: Double, seconds: Double) -> NSSound? {
        let rate = 48_000
        let n = Int(Double(rate) * seconds)
        let fade = rate / 200
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let edge = min(1, Double(min(i, n - 1 - i)) / Double(fade))
            let v = Int16(sin(2 * .pi * hz * Double(i) / Double(rate)) * 0.5 * edge * Double(Int16.max))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count))
        wav.append(pcm)
        return NSSound(data: wav)
    }
}
