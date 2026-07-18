import AppKit
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

enum CaptureError: Error {
    case noWindowForApp
    case noContentAvailable
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

    var onStreamStopped: ((Error?) -> Void)?

    private(set) var isRunning = false

    static func availableTargets() async throws -> AvailableTargets {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Only offer apps that actually have an on-screen window worth recording.
        let appsWithWindows = Set(content.windows.compactMap { $0.owningApplication?.processID })
        let apps = content.applications.filter { appsWithWindows.contains($0.processID) }
        return AvailableTargets(apps: apps, displays: content.displays)
    }

    private static func mainWindow(for app: SCRunningApplication, in content: SCShareableContent) -> SCWindow? {
        content.windows
            .filter { $0.owningApplication?.processID == app.processID && $0.isOnScreen }
            .max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }

    func start(target: CaptureTarget) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2

        switch target {
        case .app(let app):
            guard let window = Self.mainWindow(for: app, in: content) else {
                throw CaptureError.noWindowForApp
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            pixelWidth = Int((window.frame.width * scale).rounded())
            pixelHeight = Int((window.frame.height * scale).rounded())
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
            pixelWidth = Int(CGFloat(display.width) * scale)
            pixelHeight = Int(CGFloat(display.height) * scale)
        }

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
            videoEncoder?.encode(sampleBuffer)
        case .audio:
            let sample = TimedSample(sampleBuffer: sampleBuffer, isKeyframe: true)
            Task { [audioBuffer] in await audioBuffer.append(sample) }
        @unknown default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        onStreamStopped?(error)
    }
}
