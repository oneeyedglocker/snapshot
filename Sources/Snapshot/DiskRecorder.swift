import AVFoundation
import CoreMedia
import Foundation

enum DiskRecordingStopReason {
    case manual
    case sizeLimitReached
    case error(Error)
}

/// Writes video/audio straight to an .mp4 on disk in real time, for the
/// open-ended "just record this whole session" case — unlike ClipExporter,
/// which slices a fixed window out of the RAM ring buffer, this has no end
/// in sight until stopped (or the size cap trips), so nothing beyond a
/// brief startup window is ever held in memory.
final class DiskRecorder {
    private let writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private let maxBytes: Int64
    private let queue = DispatchQueue(label: "snapshot.diskrecorder")
    private var bytesWritten: Int64 = 0
    private var sessionStarted = false
    private var isFinishing = false

    // Video and audio frames arrive on separate SCStream queues, so the
    // very first ones can land a beat apart, but AVAssetWriter requires
    // every track to be added before startWriting() is called. Hold a
    // short startup window of frames until we've seen a video frame (and
    // either an audio frame or given up waiting for one), then add
    // whichever tracks we have, start the session, and flush the backlog.
    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private var startupDeadline: DispatchTime?
    private static let startupWindow: TimeInterval = 0.5

    let url: URL
    var onStopped: ((DiskRecordingStopReason) -> Void)?

    init?(url: URL, maxBytes: Int64) {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        self.writer = writer
        self.url = url
        self.maxBytes = maxBytes
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [self] in
            guard !isFinishing else { return }
            guard sessionStarted else {
                pendingVideo.append(sampleBuffer)
                considerStartingSession()
                return
            }
            append(sampleBuffer, to: videoInput)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [self] in
            guard !isFinishing else { return }
            guard sessionStarted else {
                pendingAudio.append(sampleBuffer)
                considerStartingSession()
                return
            }
            append(sampleBuffer, to: audioInput)
        }
    }

    func stop(reason: DiskRecordingStopReason = .manual) {
        queue.async { [self] in finish(reason: reason) }
    }

    private func considerStartingSession() {
        guard let firstVideo = pendingVideo.first else { return }
        if startupDeadline == nil {
            startupDeadline = .now() + Self.startupWindow
        }
        let haveAudio = !pendingAudio.isEmpty
        let deadlinePassed = startupDeadline.map { DispatchTime.now() >= $0 } ?? false
        // Keep waiting — the next appendVideo/appendAudio call (a frame or
        // two away at most) will re-check.
        guard haveAudio || deadlinePassed else { return }

        guard let videoFormat = firstVideo.formatDescription else {
            finish(reason: .error(ExportError.writerFailed("first video frame has no format description")))
            return
        }
        let newVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        newVideoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(newVideoInput) else {
            finish(reason: .error(ExportError.writerFailed("cannot add video input")))
            return
        }
        writer.add(newVideoInput)
        videoInput = newVideoInput

        if let firstAudio = pendingAudio.first, let audioFormat = firstAudio.formatDescription {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Settings.audioSampleRate,
                AVNumberOfChannelsKey: Settings.audioChannels,
                AVEncoderBitRateKey: 128_000
            ]
            let newAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: audioFormat)
            newAudioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(newAudioInput) {
                writer.add(newAudioInput)
                audioInput = newAudioInput
            }
        }

        guard writer.startWriting() else {
            finish(reason: .error(writer.error ?? ExportError.writerFailed("startWriting failed")))
            return
        }
        writer.startSession(atSourceTime: firstVideo.presentationTimeStamp)
        sessionStarted = true

        let backloggedVideo = pendingVideo
        let backloggedAudio = pendingAudio
        pendingVideo = []
        pendingAudio = []
        for sample in backloggedVideo { append(sample, to: videoInput) }
        for sample in backloggedAudio { append(sample, to: audioInput) }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, input.isReadyForMoreMediaData else { return }
        guard input.append(sampleBuffer) else { return }
        bytesWritten += Int64(CMSampleBufferGetTotalSampleSize(sampleBuffer))
        if bytesWritten >= maxBytes {
            finish(reason: .sizeLimitReached)
        }
    }

    private func finish(reason: DiskRecordingStopReason) {
        guard !isFinishing else { return }
        isFinishing = true
        pendingVideo = []
        pendingAudio = []
        guard sessionStarted else {
            onStopped?(reason)
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [self] in onStopped?(reason) }
    }
}
