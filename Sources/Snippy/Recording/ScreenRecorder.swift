import AVFoundation
import ScreenCaptureKit

/// Records a region of a display to an MP4 with ScreenCaptureKit + AVAssetWriter.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Configuration {
        var display: SCDisplay
        /// Region in display-local points, top-left origin.
        var sourceRect: CGRect
        var scale: CGFloat
        var fps: Int
        var showsCursor: Bool
        var systemAudio: Bool
        var microphone: Bool
        var excludedWindows: [SCWindow]
        var outputURL: URL
        var highQuality: Bool
    }

    let configuration: Configuration
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var lastVideoTime = CMTime.zero
    private let queue = DispatchQueue(label: "app.snippy.recorder")

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func start() async throws {
        let c = configuration
        let width = Self.even(c.sourceRect.width * c.scale)
        let height = Self.even(c.sourceRect.height * c.scale)

        let filter = SCContentFilter(display: c.display, excludingWindows: c.excludedWindows)
        let config = SCStreamConfiguration()
        config.sourceRect = c.sourceRect
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(c.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = c.showsCursor
        config.queueDepth = 8
        config.capturesAudio = c.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        if c.microphone, #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }

        let writer = try AVAssetWriter(outputURL: c.outputURL, fileType: .mp4)
        // H.264 tops out at 4096 px; use HEVC for bigger (e.g. 5K) captures.
        let codec: AVVideoCodecType = (width > 4096 || height > 2304) ? .hevc : .h264
        let pixels = Double(width * height)
        let bitrate = pixels * Double(c.fps) * (c.highQuality ? 0.25 : 0.1)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(2_000_000, min(bitrate, 80_000_000)),
            AVVideoExpectedSourceFrameRateKey: c.fps,
            AVVideoMaxKeyFrameIntervalKey: c.fps * 2,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw SnippyError("Can't record at \(width)×\(height).") }
        writer.add(video)

        if c.systemAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 2))
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) { writer.add(audio); audioInput = audio }
        }
        if c.microphone, #available(macOS 15.0, *) {
            let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 1))
            mic.expectsMediaDataInRealTime = true
            if writer.canAdd(mic) { writer.add(mic); micInput = mic }
        }

        guard writer.startWriting() else {
            throw writer.error ?? SnippyError("Couldn't start writing the recording.")
        }
        self.writer = writer
        videoInput = video

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if c.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if c.microphone, #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws -> URL {
        let endTime = CMClockGetTime(CMClockGetHostTimeClock())
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                guard let writer, sessionStarted else {
                    writer?.cancelWriting()
                    cont.resume(throwing: SnippyError("No video frames were captured."))
                    return
                }
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                micInput?.markAsFinished()
                writer.endSession(atSourceTime: CMTimeMaximum(endTime, lastVideoTime))
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume(returning: self.configuration.outputURL)
                    } else {
                        cont.resume(throwing: writer.error ?? SnippyError("The recording couldn't be finalized."))
                    }
                }
            }
        }
    }

    func cancel() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        queue.sync { writer?.cancelWriting() }
        try? FileManager.default.removeItem(at: configuration.outputURL)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing else { return }

        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: rawStatus), status == .complete,
                  let videoInput else { return }
            let time = sampleBuffer.presentationTimeStamp
            if !sessionStarted {
                writer.startSession(atSourceTime: time)
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
                lastVideoTime = time
            }
            return
        }

        guard sessionStarted, sampleBuffer.presentationTimeStamp >= lastVideoTime - CMTime(value: 1, timescale: 2)
        else { return }
        if type == .audio {
            if let audioInput, audioInput.isReadyForMoreMediaData { audioInput.append(sampleBuffer) }
        } else if let micInput, micInput.isReadyForMoreMediaData {
            micInput.append(sampleBuffer)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    // MARK: Helpers

    private static func even(_ value: CGFloat) -> Int {
        let v = max(2, Int(value.rounded()))
        return v % 2 == 0 ? v : v - 1
    }

    private static func aacSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96000 : 160_000,
        ]
    }
}

enum GIFExporter {
    /// Converts a recorded video into an animated GIF.
    static func export(videoURL: URL, to gifURL: URL, fps: Int, maxWidth: Int) async throws {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw SnippyError("The recording is empty.") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxWidth, height: 10_000)

        let count = max(1, Int(duration * Double(fps)))
        guard let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, "com.compuserve.gif" as CFString,
                                                                count, nil) else {
            throw SnippyError("Couldn't create the GIF file.")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = 1.0 / Double(fps)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary

        var previous: CGImage?
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) * delay, preferredTimescale: 600)
            let frame: CGImage? = (try? await generator.image(at: time))?.image ?? previous
            guard let frame else { continue }
            CGImageDestinationAddImage(destination, frame, frameProperties)
            previous = frame
        }
        guard CGImageDestinationFinalize(destination) else { throw SnippyError("Couldn't write the GIF.") }
    }
}
