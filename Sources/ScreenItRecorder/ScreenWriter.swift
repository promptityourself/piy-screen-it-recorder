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

/// Writes one display's frames (and the apps' sound) to a .mov. The mic never goes in a screen
/// file: the first screen's stream hands it to a MicWriter, its own file. Sample callbacks run on `queue`.
/// `@unchecked Sendable`: its mutable state is touched only on `queue`.
final class ScreenWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let url: URL
    let queue = DispatchQueue(label: "ScreenWriter", qos: .userInteractive)
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    /// The mic's own file; on the first screen's writer only, which also sets its start.
    private let mic: MicWriter?
    /// The apps' sound (ScreenCaptureKit's system audio), the file's only audio track.
    private let appAudio: AVAssetWriterInput?
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

    init(url: URL, width: Int, height: Int, codec: Codec, quality: Quality, mic: MicWriter?,
         appSound: Bool, area: CGRect?, onError: @escaping (Error) -> Void) throws {
        self.url = url
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
        if appSound {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Recorder.appSoundRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ])
            input.expectsMediaDataInRealTime = true
            input.metadata = [Self.trackName("App sound")]
            guard writer.canAdd(input) else { throw RecError("Cannot write the app sound") }
            writer.add(input)
            appAudio = input
        } else {
            appAudio = nil
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
            }
            guard pts > lastFrameTime else { return }
            if video.isReadyForMoreMediaData {
                if !video.append(buffer) { return report() }
                lastFrame = buffer
                lastFrameTime = pts
            }
        case .microphone:
            guard let startTime else { return }
            mic?.append(buffer, from: startTime)
        default:
            break
        }
    }

    /// The apps' sound, from Recorder's one sound stream (shared by every screen file).
    func appendAppSound(_ buffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = buffer
        queue.async { [self] in
            guard !finishing, let appAudio, let startTime, buffer.presentationTimeStamp >= startTime,
                  appAudio.isReadyForMoreMediaData else { return }
            if !appAudio.append(buffer) { report() }
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
        appAudio?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? RecError("\(url.lastPathComponent) did not save.")
        }
        try await mic?.finish()
    }

    /// A failed writer (for example a full disk) fails every later append: report it once.
    private func report() {
        guard !reportedFailure else { return }
        reportedFailure = true
        onError(writer.error ?? RecError("\(url.lastPathComponent) stopped saving."))
    }
}

/// The mic on its own, as uncompressed 24-bit WAV: the cleanest source for the edit, and never
/// mixed into a screen file (the screen files had it too, and with the app sound that was an echo).
/// Time 0 is the first screen file's first frame, so it lines up with that file as it is.
/// Fed from that screen's ScreenWriter.queue only.
final class MicWriter: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var failed = false
    private let onError: (Error) -> Void

    init(url: URL, device: AVCaptureDevice, onError: @escaping (Error) -> Void) throws {
        self.url = url
        self.onError = onError
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee
        writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: asbd.map { $0.mSampleRate } ?? 48_000,
            AVNumberOfChannelsKey: min(2, max(1, Int(asbd?.mChannelsPerFrame ?? 1))),
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecError("Cannot write the microphone audio") }
        writer.add(input)
    }

    /// `start`: the first screen frame's time; earlier mic samples are dropped.
    func append(_ buffer: CMSampleBuffer, from start: CMTime) {
        guard !failed, buffer.presentationTimeStamp >= start else { return }
        if !started {
            guard writer.startWriting() else { return report() }
            writer.startSession(atSourceTime: start)
            started = true
        }
        if input.isReadyForMoreMediaData, !input.append(buffer) { report() }
    }

    /// Call after the screen writer that feeds it finished.
    func finish() async throws {
        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecError("\(url.lastPathComponent) got no sound from the microphone.")
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? RecError("\(url.lastPathComponent) did not save.")
        }
    }

    private func report() {
        guard !failed else { return }
        failed = true
        onError(writer.error ?? RecError("\(url.lastPathComponent) stopped saving."))
    }
}
