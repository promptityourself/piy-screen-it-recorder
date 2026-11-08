import AVFoundation
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

/// Writes one display's frames plus the mic to a .mov. Sample callbacks run on `queue`.
/// `@unchecked Sendable`: its mutable state is touched only on `queue`.
final class ScreenWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let url: URL
    let queue = DispatchQueue(label: "ScreenWriter", qos: .userInteractive)
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    /// The apps' sound (ScreenCaptureKit's system audio), a second track after the mic's.
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
    private var lastSample = ContinuousClock.now
    private var reportedFailure = false
    private let onError: (Error) -> Void

    /// QuickTime metadata key for the recorded part of the display: "x y w h" as fractions of it,
    /// origin top left. Absent for a whole display. Playback puts the video back there.
    static let areaKey = "com.promptityourself.screen-it-recorder.area"
    static let areaID = AVMetadataItem.identifier(forKey: areaKey, keySpace: .quickTimeMetadata)!

    init(url: URL, width: Int, height: Int, codec: Codec, quality: Quality, mic: AVCaptureDevice?,
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

        if let mic {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(mic.activeFormat.formatDescription)?.pointee
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.map { $0.mSampleRate } ?? 48_000,
                AVNumberOfChannelsKey: min(2, max(1, Int(asbd?.mChannelsPerFrame ?? 1))),
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = true
            input.metadata = [Self.trackName("Microphone")]
            guard writer.canAdd(input) else { throw RecError("Cannot write the microphone audio") }
            writer.add(input)
            audio = input
        } else {
            audio = nil
        }
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
    var silence: Duration { queue.sync { ContinuousClock.now - lastSample } }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lastSample = .now
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
            guard let audio, let startTime, buffer.presentationTimeStamp >= startTime,
                  audio.isReadyForMoreMediaData else { return }
            if !audio.append(buffer) { report() }
        case .audio:
            guard let appAudio, let startTime, buffer.presentationTimeStamp >= startTime,
                  appAudio.isReadyForMoreMediaData else { return }
            if !appAudio.append(buffer) { report() }
        default:
            break
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
        audio?.markAsFinished()
        appAudio?.markAsFinished()
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
