import AVFoundation
import os
import ScreenCaptureKit

/// Recording quality. SCRecordingOutput has no quality setting at all (it wrote ~2.8 Mbit/s HEVC
/// at 1440p, measured 2026-10-11), so each display's frames go through our own AVAssetWriter.
enum Quality: String, CaseIterable, Identifiable {
    case standard, high, maximum
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// HEVC average bitrate at 2560×1440 30 fps; scaled by pixel count for other sizes.
    var hevcBitsAt1440: Int {
        switch self {
        case .standard: 8_000_000
        case .high: 20_000_000
        case .maximum: 40_000_000
        }
    }

    var prores: AVVideoCodecType {
        switch self {
        case .standard: .proRes422LT
        case .high: .proRes422
        case .maximum: .proRes422HQ
        }
    }
}

/// Mbit/s for one display, measured 2026-10-11 on a 5K Studio Display with a moving test
/// pattern (a still screen uses far less). Rows: codec + resolution; columns: Standard, High, Maximum.
enum MeasuredRate {
    static func mbps(_ codec: Codec, _ resolution: Resolution, _ quality: Quality) -> Double {
        let row: [Double] = switch (codec, resolution) {
        case (.hevc, .p1440): [7.1, 13.4, 23.3]
        case (.hevc, .native): [21.4, 31.7, 52.0]
        case (.prores, .p1440): [77.8, 107.2, 167.2]
        case (.prores, .native): [200.7, 281.0, 462.4]
        }
        return row[Quality.allCases.firstIndex(of: quality)!]
    }
}

enum Codec: String, CaseIterable, Identifiable {
    case hevc, prores
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC (small files)" : "ProRes (smooth editing, very large files)" }
}

enum Resolution: String, CaseIterable, Identifiable {
    case p1440, native
    var id: String { rawValue }
    var label: String { self == .p1440 ? "1440p" : "Native (full display resolution)" }
}

/// Writes one display's frames to a .mov, plus our own countdown tones as the only audio track (an
/// exact sync marker). The mic and the apps' sound never go in a screen file: each has its own
/// AudioFile. Sample callbacks run on `queue`.
/// `@unchecked Sendable`: its mutable state is touched only on `queue`.
final class ScreenWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let url: URL
    let queue = DispatchQueue(label: "ScreenWriter", qos: .userInteractive)
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    /// The mic's own file; fed from the first screen's stream only.
    private let mic: AudioFile?
    /// Set from the first frame of any screen: time 0 of every audio file.
    private let anchor: Anchor
    /// Our countdown tones, from Recorder's tone stream; nil when the countdown is off.
    private let tones: AVAssetWriterInput?
    private var startTime: CMTime?
    /// The last complete frame. ScreenCaptureKit sends a new image only when the screen changes,
    /// so a still screen would leave the video track short of the audio (measured: 0.87 s of
    /// video in a 4.2 s file). It is repeated instead, for a steady frame rate up to the stop.
    private var lastFrame: CMSampleBuffer?
    private var lastFrameTime = CMTime.negativeInfinity
    private var latestTime = CMTime.negativeInfinity  // the newest time any sample carried
    private let frameInterval = CMTime(value: 1, timescale: Recorder.fps)
    private var finishing = false
    /// Read from the main actor by the watchdog, so behind a lock and not on `queue`.
    private let lastSample = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    private var reportedFailure = false
    private let onError: (Error) -> Void

    /// QuickTime metadata key for the recorded part of the display: "x y w h" as fractions of it,
    /// origin top left. Absent for a whole display. Playback puts the video back there.
    static let areaKey = "com.promptityourself.screen-it-recorder.area"
    static let areaID = AVMetadataItem.identifier(forKey: areaKey, keySpace: .quickTimeMetadata)!

    init(url: URL, width: Int, height: Int, codec: Codec, quality: Quality, mic: AudioFile?, anchor: Anchor,
         tones: Bool, area: CGRect?, onError: @escaping (Error) -> Void) throws {
        self.url = url
        self.anchor = anchor
        self.onError = onError
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        if let area {
            let item = AVMutableMetadataItem()
            item.identifier = Self.areaID
            item.value = [area.minX, area.minY, area.width, area.height].map { String(Double($0)) }.joined(separator: " ") as NSString
            writer.metadata = [item]
        }

        var settings: [String: Any] = [
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // Tag what ScreenCaptureKit delivers (sRGB → BT.709 matrix), so key colours stay exact.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        switch codec {
        case .hevc:
            let pixels = Double(width * height) / Double(2560 * 1440)
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(Double(quality.hevcBitsAt1440) * pixels),
                AVVideoExpectedSourceFrameRateKey: Int(Recorder.fps),
                AVVideoMaxKeyFrameIntervalKey: Int(Recorder.fps) * 2,  // a keyframe every 2 s: quick scrubbing in FCP
            ]
        case .prores:
            settings[AVVideoCodecKey] = quality.prores
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecError("Cannot write \(codec.label) video") }
        writer.add(video)

        self.mic = mic
        if tones {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Recorder.appSoundRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ])
            input.expectsMediaDataInRealTime = true
            input.metadata = [Self.trackName("Countdown tones")]
            guard writer.canAdd(input) else { throw RecError("Cannot write the countdown tones") }
            writer.add(input)
            self.tones = input
        } else {
            self.tones = nil
        }
        super.init()
    }

    private static func trackName(_ name: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeUserDataTrackName
        item.value = name as NSString
        return item
    }

    /// Seconds since the stream last delivered anything (a frame, an idle frame, or audio).
    var silence: Duration { ContinuousClock.now - lastSample.withLock { $0 } }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lastSample.withLock { $0 = .now }
        guard !finishing, buffer.isValid else { return }
        let pts = buffer.presentationTimeStamp
        if pts.isValid, pts > latestTime { latestTime = pts }
        switch type {
        case .screen:
            // Only complete frames carry an image; idle frames (nothing changed) carry none.
            let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]]
            let complete = (info?.first?[.status] as? Int).flatMap(SCFrameStatus.init) == .complete
            guard complete, CMSampleBufferGetImageBuffer(buffer) != nil else {
                repeatLastFrame(upTo: pts)
                return
            }
            if startTime == nil {
                guard writer.startWriting() else { return report() }
                writer.startSession(atSourceTime: pts)
                startTime = pts
                anchor.set(pts)
            }
            guard pts > lastFrameTime else { return }
            if video.isReadyForMoreMediaData {
                if !video.append(buffer) { return report() }
                lastFrame = buffer
                lastFrameTime = pts
            }
        case .microphone:
            mic?.append(buffer)
        default:
            break
        }
    }

    /// Our countdown tones, from Recorder's tone stream (shared by every screen file).
    func appendTones(_ buffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = buffer
        queue.async { [self] in
            guard !finishing, let tones, let startTime, buffer.presentationTimeStamp >= startTime,
                  tones.isReadyForMoreMediaData else { return }
            if !tones.append(buffer) { report() }
        }
    }

    /// Fill the gap since the last frame with copies of it, one per frame interval.
    private func repeatLastFrame(upTo time: CMTime) {
        guard let lastFrame, time.isValid else { return }
        var next = lastFrameTime + frameInterval
        while next <= time, video.isReadyForMoreMediaData {
            var timing = CMSampleTimingInfo(duration: frameInterval, presentationTimeStamp: next,
                                            decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: lastFrame,
                                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                  sampleBufferOut: &copy)
            guard let copy, video.append(copy) else { return report() }
            lastFrameTime = next
            next = next + frameInterval
        }
    }

    /// Call after the stream stopped. Throws when the file is not usable.
    func finish() async throws {
        let started = queue.sync {
            finishing = true
            repeatLastFrame(upTo: latestTime)  // the video runs to the stop, as the audio does
            return startTime != nil
        }
        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecError("\(url.lastPathComponent) got no frames from the display.")
        }
        video.markAsFinished()
        tones?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? RecError("\(url.lastPathComponent) did not save.")
        }
    }

    /// A failed writer (for example a full disk) fails every later append: report it once.
    private func report() {
        guard !reportedFailure else { return }
        reportedFailure = true
        onError(writer.error ?? RecError("\(url.lastPathComponent) stopped saving."))
    }
}

/// Time 0 of every audio file: the first frame of any screen file. Screen files start within a
/// frame or so of it; the countdown tones in each give the exact offset.
final class Anchor: Sendable {
    private let time = OSAllocatedUnfairLock<CMTime?>(initialState: nil)
    func set(_ t: CMTime) { time.withLock { if $0 == nil { $0 = t } } }
    var value: CMTime? { time.withLock { $0 } }
}

/// One sound on its own, as uncompressed 24-bit WAV: the mic, or one app. Never mixed into a screen
/// file, so each can be edited on its own. Starts at the anchor, and any gap (an app that opens late,
/// or quits and reopens: ScreenCaptureKit sends nothing while it is not running) becomes silence,
/// so the file stays in sync from start to end. Fed from one serial queue.
final class AudioFile: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let anchor: Anchor
    private var next: CMTime?  // where the next sample must start
    private var format: CMAudioFormatDescription?
    private var failed = false
    private let onError: (Error) -> Void

    init(url: URL, rate: Double, channels: Int, anchor: Anchor, onError: @escaping (Error) -> Void) throws {
        self.url = url
        self.anchor = anchor
        self.onError = onError
        writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: min(2, max(1, channels)),
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecError("Cannot write \(url.lastPathComponent)") }
        writer.add(input)
    }

    /// A mic's file, in the mic's own sample rate and channels (at most 2).
    convenience init(url: URL, mic: AVCaptureDevice, anchor: Anchor, onError: @escaping (Error) -> Void) throws {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(mic.activeFormat.formatDescription)?.pointee
        try self.init(url: url, rate: asbd.map { $0.mSampleRate } ?? 48_000,
                      channels: Int(asbd?.mChannelsPerFrame ?? 1), anchor: anchor, onError: onError)
    }

    func append(_ buffer: CMSampleBuffer) {
        guard !failed, buffer.isValid, let start = anchor.value else { return }
        let pts = buffer.presentationTimeStamp
        guard pts >= start else { return }
        if next == nil {
            guard writer.startWriting() else { return report() }
            writer.startSession(atSourceTime: start)
            next = start
        }
        format = buffer.formatDescription ?? format
        fillSilence(upTo: pts)
        guard !failed else { return }
        if !append(sample: buffer) { return report() }
        next = pts + buffer.duration
    }

    /// `end`: the stop's time (host clock), so every file runs to the stop. False: no sound came
    /// at all (an app that never ran), and there is no file.
    func finish(at end: CMTime) async throws -> Bool {
        guard next != nil else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return false
        }
        fillSilence(upTo: end)
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? RecError("\(url.lastPathComponent) did not save.")
        }
        return true
    }

    /// Silence from `next` to `time`, in 1 s pieces, in the format of the last sound.
    private func fillSilence(upTo time: CMTime) {
        guard let format, var at = next,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
        let rate = asbd.mSampleRate
        let tolerance = CMTime(seconds: 0.005, preferredTimescale: 48_000)
        while time - at > tolerance {
            let frames = min(Int(rate), Int(((time - at).seconds * rate).rounded()))
            guard frames > 0 else { break }
            let planes = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(asbd.mChannelsPerFrame) : 1
            let bytes = frames * Int(asbd.mBytesPerFrame) * planes
            var block: CMBlockBuffer?
            var sample: CMSampleBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                     blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                     blockBufferOut: &block) == noErr, let block,
                  CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                             dataLength: bytes) == noErr,
                  CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                      allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                      presentationTimeStamp: at, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
                  let sample, append(sample: sample)
            else { return report() }
            at = at + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
            next = at
        }
    }

    /// The WAV writer is ready again within moments; waiting keeps the timing, a drop would not.
    private func append(sample: CMSampleBuffer) -> Bool {
        for _ in 0..<200 where !input.isReadyForMoreMediaData { usleep(1_000) }
        return input.append(sample)
    }

    private func report() {
        guard !failed else { return }
        failed = true
        onError(writer.error ?? RecError("\(url.lastPathComponent) stopped saving."))
    }
}
