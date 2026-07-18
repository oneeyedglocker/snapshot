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

    var onStreamStopped: ((Error?) -> Void)?

    private(set) var isRunning = false

    static func availableTargets() async throws -> AvailableTargets {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Only offer apps that actually have an on-screen window worth recording.
        let appsWithWindows = Set(content.windows.compactMap { $0.owningApplication?.processID })
        let apps = content.applications.filter { appsWithWindows.contains($0.processID) }
        return AvailableTargets(apps: apps, displays: content.displays)
    }

    /// Prefers an on-screen window, but falls back to the largest window owned
    /// by the process at all if none are currently flagged on-screen — SCWindow's
    /// isOnScreen has been observed to lag by a beat right after an app launches
    /// or regains focus, and a stale flag shouldn't be a hard failure.
    private static func mainWindow(for app: SCRunningApplication, in content: SCShareableContent) -> SCWindow? {
        let owned = content.windows.filter { $0.owningApplication?.processID == app.processID }
        let onScreen = owned.filter(\.isOnScreen)
        let pool = onScreen.isEmpty ? owned : onScreen
        return pool.max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
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
                let owners = Set(content.windows.compactMap { $0.owningApplication?.applicationName }).sorted()
                throw CaptureError.noWindowForApp(
                    "No window found for \"\(app.applicationName)\" (pid \(app.processID), bundle \(app.bundleIdentifier)). "
                    + "ScreenCaptureKit currently reports \(content.windows.count) window(s) total, owned by: "
                    + (owners.isEmpty ? "(none)" : owners.joined(separator: ", ")) + "."
                )
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

    /// Applies the current Settings.bufferSeconds to both buffers immediately,
    /// so changing clip length in the menu takes effect without a restart.
    func applyBufferWindow() {
        let seconds = Settings.bufferSeconds
        Task { [videoBuffer] in await videoBuffer.setWindowSeconds(seconds) }
        Task { [audioBuffer] in await audioBuffer.setWindowSeconds(seconds) }
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
        case .microphone:
            break // we don't request microphone capture (see SCStreamConfiguration.capturesMicrophone, unused)
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
