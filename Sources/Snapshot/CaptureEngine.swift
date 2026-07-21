import AppKit
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum CaptureTarget {
    case app(SCRunningApplication)
    case display(SCDisplay)

    var displayName: String {
        switch self {
        case .app(let app): return app.applicationName
        case .display(let display): return "Display \(display.displayID)"
        }
    }
}

struct AvailableTargets {
    let apps: [SCRunningApplication]
    let displays: [SCDisplay]
}

enum CaptureError: Error, CustomStringConvertible {
    case noWindowForApp(String)
    case noContentAvailable

    var description: String {
        switch self {
        case .noWindowForApp(let detail): return detail
        case .noContentAvailable: return "No capturable content available."
        }
    }
}

/// Owns the ScreenCaptureKit stream and fans raw sample buffers out to the
/// video encoder (video) and straight into the ring buffer (audio, kept as
/// raw PCM since it's cheap and AVAssetWriter will AAC-encode it on export).
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var videoEncoder: VideoEncoder?

    let videoBuffer = ReplayRingBuffer(windowSeconds: Settings.bufferSeconds)
    let audioBuffer = ReplayRingBuffer(windowSeconds: Settings.bufferSeconds)

    private let videoQueue = DispatchQueue(label: "snapshot.capture.video")
    private let audioQueue = DispatchQueue(label: "snapshot.capture.audio")

    // Frame-timing diagnostics, only ever touched from videoQueue (the
    // SCStreamOutput callback for .screen runs serially there).
    private var lastVideoFramePTS: CMTime?
    private var framesSinceLog = 0
    private var gappyFramesSinceLog = 0
    private var worstGapSinceLog: Double = 0
    private var lastFrameLogTime = Date()
    private var hasLoggedFirstVideoFrameSize = false
    private var configuredPixelWidth = 0
    private var configuredPixelHeight = 0

    // Audio diagnostics. hasLoggedFirstAudioSample is only touched from
    // audioQueue. The two counters below are written from audioQueue and
    // read/reset from videoQueue's 5s timer (so an audio heartbeat prints
    // even after audio delivery stops), so they're guarded by a lock.
    private var hasLoggedFirstAudioSample = false
    private let audioStatsLock = NSLock()
    private var audioSamplesSinceVideoLog = 0
    private var audioPeakSinceVideoLog: Float32 = 0

    var onStreamStopped: ((Error?) -> Void)?

    private(set) var isRunning = false

    /// Below this, a window is almost certainly a background/utility panel
    /// rather than something worth offering as a capture target.
    private static let minimumWindowDimension: CGFloat = 150

    static func availableTargets() async throws -> AvailableTargets {
        // onScreenWindowsOnly: false — true fullscreen apps run in their own
        // dedicated Space, and with `true` here ScreenCaptureKit silently
        // omits their window even though it's clearly visible/capturable.
        // We filter for "worth recording" by size instead.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let substantialWindows = content.windows.filter {
            $0.frame.width >= minimumWindowDimension && $0.frame.height >= minimumWindowDimension
        }
        let appsWithWindows = Set(substantialWindows.compactMap { $0.owningApplication?.processID })
        let apps = content.applications.filter { appsWithWindows.contains($0.processID) }
        return AvailableTargets(apps: apps, displays: content.displays)
    }

    /// Prefers an on-screen window, but falls back to the largest window owned
    /// by the process at all if none are currently flagged on-screen — SCWindow's
    /// isOnScreen has been observed to lag by a beat right after an app launches
    /// or regains focus (and is unreliable for fullscreen windows in their own
    /// Space), so a stale/false flag shouldn't be a hard failure.
    private static func mainWindow(for app: SCRunningApplication, in content: SCShareableContent) -> SCWindow? {
        let owned = content.windows.filter {
            $0.owningApplication?.processID == app.processID
            && $0.frame.width >= minimumWindowDimension
            && $0.frame.height >= minimumWindowDimension
        }
        let onScreen = owned.filter(\.isOnScreen)
        let pool = onScreen.isEmpty ? owned : onScreen
        return pool.max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }

    func start(target: CaptureTarget) async throws {
        await stop()

        // See availableTargets() — onScreenWindowsOnly: false so fullscreen
        // app windows (their own Space) still resolve correctly.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter: SCContentFilter
        let contentSizePoints: CGSize

        switch target {
        case .app(let app):
            guard let window = Self.mainWindow(for: app, in: content) else {
                let owners = Set(content.windows.compactMap { $0.owningApplication?.applicationName }).sorted()
                throw CaptureError.noWindowForApp(
                    "No window found for \"\(app.applicationName)\" (pid \(app.processID), bundle \(app.bundleIdentifier)). "
                    + "ScreenCaptureKit currently reports \(content.windows.count) window(s) total, owned by: "
                    + (owners.isEmpty ? "(none)" : owners.joined(separator: ", ")) + "."
                )
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            contentSizePoints = window.frame.size
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
            contentSizePoints = CGSize(width: display.width, height: display.height)
        }

        // Physical pixel dimensions. NSScreen.main's backing scale factor was
        // wrong here whenever the captured content wasn't on the main screen,
        // or the display was in a scaled (non-native) resolution mode — it
        // was producing captures well below the display's real pixel
        // resolution (e.g. 1706x986 instead of ~3412x1972 on a scaled Retina
        // display). SCContentFilter's own pointPixelScale (macOS 14+) is the
        // correct source of truth since it reflects the actual capture, not
        // a guess based on whichever screen AppKit considers "main."
        let pixelWidth: Int
        let pixelHeight: Int
        if #available(macOS 14.0, *) {
            let pixelScale = CGFloat(filter.pointPixelScale)
            pixelWidth = Int((filter.contentRect.width * pixelScale).rounded())
            pixelHeight = Int((filter.contentRect.height * pixelScale).rounded())
        } else {
            let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
            pixelWidth = Int((contentSizePoints.width * scale).rounded())
            pixelHeight = Int((contentSizePoints.height * scale).rounded())
        }
        NSLog("%@", "Snapshot: capture resolution: \(pixelWidth)x\(pixelHeight) pixels (content \(contentSizePoints.width)x\(contentSizePoints.height) points)")

        let config = SCStreamConfiguration()
        config.width = max(pixelWidth, 2)
        config.height = max(pixelHeight, 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Settings.frameRate)
        config.queueDepth = 8
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = Int(Settings.audioSampleRate)
        config.channelCount = Settings.audioChannels
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        guard let encoder = VideoEncoder(
            width: Int32(config.width),
            height: Int32(config.height),
            onEncodedFrame: { [videoBuffer] sample in
                Task { await videoBuffer.append(sample) }
            }
        ) else {
            throw CaptureError.noContentAvailable
        }
        videoEncoder = encoder

        await videoBuffer.reset()
        await audioBuffer.reset()

        videoQueue.sync {
            lastVideoFramePTS = nil
            framesSinceLog = 0
            gappyFramesSinceLog = 0
            worstGapSinceLog = 0
            lastFrameLogTime = Date()
            hasLoggedFirstVideoFrameSize = false
            configuredPixelWidth = config.width
            configuredPixelHeight = config.height
        }
        audioQueue.sync {
            hasLoggedFirstAudioSample = false
        }
        audioStatsLock.lock()
        audioSamplesSinceVideoLog = 0
        audioPeakSinceVideoLog = 0
        audioStatsLock.unlock()

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()

        stream = newStream
        isRunning = true
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        videoEncoder?.invalidate()
        videoEncoder = nil
        isRunning = false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            logFrameTiming(sampleBuffer.presentationTimeStamp)
            logVideoFrameSizeIfNeeded(sampleBuffer)
            videoEncoder?.encode(sampleBuffer)
        case .audio:
            logAudioTiming(sampleBuffer)
            let sample = TimedSample(sampleBuffer: sampleBuffer, isKeyframe: true)
            Task { [audioBuffer] in await audioBuffer.append(sample) }
        case .microphone:
            break // we don't request microphone capture (see SCStreamConfiguration.capturesMicrophone, unused)
        @unknown default:
            break
        }
    }

    /// Diagnoses whether ScreenCaptureKit is delivering frames at a steady
    /// cadence. A real gap here means the system (game + encoder +
    /// everything else sharing the GPU/media engine) can't keep up in real
    /// time — independent of anything downstream in our own pipeline. Only
    /// ever called from videoQueue, so these counters don't need locking.
    private func logFrameTiming(_ pts: CMTime) {
        let expectedInterval = 1.0 / Double(Settings.frameRate)
        if let lastVideoFramePTS {
            let gap = CMTimeGetSeconds(pts - lastVideoFramePTS)
            if gap > expectedInterval * 1.5 {
                gappyFramesSinceLog += 1
                worstGapSinceLog = max(worstGapSinceLog, gap)
            }
        }
        lastVideoFramePTS = pts
        framesSinceLog += 1

        let now = Date()
        let elapsed = now.timeIntervalSince(lastFrameLogTime)
        if elapsed >= 5 {
            // Read+reset the audio counters here (not on audioQueue) so an
            // audio heartbeat still prints every 5s even after audio delivery
            // has stopped entirely — the whole point is to see WHEN it stops.
            audioStatsLock.lock()
            let audioCount = audioSamplesSinceVideoLog
            let audioPeak = audioPeakSinceVideoLog
            audioSamplesSinceVideoLog = 0
            audioPeakSinceVideoLog = 0
            audioStatsLock.unlock()

            NSLog(
                "%@",
                String(
                    format: "Snapshot: video frames in last %.1fs: %d (%.1f fps), gaps>1.5x: %d, worst gap: %.0fms | audio samples: %d, peak: %f",
                    elapsed, framesSinceLog, Double(framesSinceLog) / elapsed, gappyFramesSinceLog, worstGapSinceLog * 1000,
                    audioCount, audioPeak
                )
            )
            framesSinceLog = 0
            gappyFramesSinceLog = 0
            worstGapSinceLog = 0
            lastFrameLogTime = now
        }
    }

    /// One-time (per session) check that the encoder's configured dimensions
    /// (set from SCStreamConfiguration.width/height at start()) actually
    /// match what ScreenCaptureKit is really delivering. VTCompressionSession
    /// is created once with fixed dimensions and silently rescales/crops any
    /// incoming CVPixelBuffer that doesn't match — so a mismatch here would
    /// silently undo the resolution fix rather than produce an obvious error.
    private func logVideoFrameSizeIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        guard !hasLoggedFirstVideoFrameSize, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        hasLoggedFirstVideoFrameSize = true
        let actualWidth = CVPixelBufferGetWidth(imageBuffer)
        let actualHeight = CVPixelBufferGetHeight(imageBuffer)
        let matches = actualWidth == configuredPixelWidth && actualHeight == configuredPixelHeight
        NSLog(
            "%@",
            "Snapshot: first video frame: actual pixel buffer \(actualWidth)x\(actualHeight), encoder configured for "
            + "\(configuredPixelWidth)x\(configuredPixelHeight)" + (matches ? " (match)" : " (MISMATCH — VideoToolbox will silently rescale)")
        )
    }

    /// Records that an audio sample arrived and its peak amplitude, into
    /// lock-guarded counters that the video 5s timer drains and logs. The
    /// key question is WHEN audio delivery stops (the earlier run showed only
    /// ~1.2s of audio in a 21s recording), and reporting from the reliably-
    /// firing video timer — rather than here, which stops being called the
    /// moment audio stops — is what makes that visible. Called from audioQueue.
    private func logAudioTiming(_ sampleBuffer: CMSampleBuffer) {
        if !hasLoggedFirstAudioSample {
            hasLoggedFirstAudioSample = true
            NSLog("%@", "Snapshot: first audio sample received, pts=\(CMTimeGetSeconds(sampleBuffer.presentationTimeStamp))s")
            logAudioFormatAndContent(sampleBuffer)
        }
        let peak = peakAmplitude(of: sampleBuffer) ?? 0
        audioStatsLock.lock()
        audioSamplesSinceVideoLog += 1
        audioPeakSinceVideoLog = max(audioPeakSinceVideoLog, peak)
        audioStatsLock.unlock()
    }

    /// One-time (per session) inspection of the actual audio format and
    /// whether the source buffer contains real signal or silence — the
    /// sample-count/timing diagnostics above only prove buffers arrive on
    /// schedule, not that they carry audible content. If this shows real
    /// non-zero signal but clips still play silent, the bug is downstream
    /// (export/encode); if peak is ~0 here, ScreenCaptureKit itself isn't
    /// capturing real audio for this target.
    private func logAudioFormatAndContent(_ sampleBuffer: CMSampleBuffer) {
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
            let isNonInterleaved = asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
            NSLog(
                "%@",
                "Snapshot: audio format: sampleRate=\(asbd.pointee.mSampleRate) channels=\(asbd.pointee.mChannelsPerFrame) "
                + "bitsPerChannel=\(asbd.pointee.mBitsPerChannel) isFloat=\(isFloat) isNonInterleaved=\(isNonInterleaved) "
                + "bytesPerFrame=\(asbd.pointee.mBytesPerFrame) formatFlags=\(asbd.pointee.mFormatFlags)"
            )
        } else {
            NSLog("%@", "Snapshot: could not read audio format description")
        }
    }

    /// Returns the peak absolute float sample across all channel buffers of
    /// one audio sample buffer, or nil if the data can't be read. Non-
    /// interleaved stereo delivers one AudioBuffer per channel, so a default
    /// single-buffer AudioBufferList is too small (that was the -12737
    /// kCMSampleBufferError_ArrayTooSmall seen earlier) — size it dynamically.
    private func peakAmplitude(of sampleBuffer: CMSampleBuffer) -> Float32? {
        var neededSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, neededSize > 0 else { return nil }
        let ablPointer = UnsafeMutableRawPointer.allocate(byteCount: neededSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPointer.deallocate() }
        let audioBufferListPtr = ablPointer.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPtr,
            bufferListSize: neededSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferListPtr)
        var peak: Float32 = 0
        for buffer in buffers {
            guard let mData = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let samples = mData.assumingMemoryBound(to: Float32.self)
            for i in 0..<sampleCount {
                peak = max(peak, abs(samples[i]))
            }
        }
        return peak
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        onStreamStopped?(error)
    }
}
