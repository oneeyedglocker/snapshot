import CoreMedia
import Foundation
import VideoToolbox

/// Wraps a VTCompressionSession to turn raw captured frames into H.265/HEVC
/// (falling back to H.264 on hardware without a HEVC encoder), one frame at
/// a time, in real time. We disable frame reordering so decode order always
/// matches display order — that keeps the ring-buffer/export logic (which
/// just slices a contiguous array of encoded samples) simple and correct.
final class VideoEncoder {
    private var session: VTCompressionSession?
    private let onEncodedFrame: (TimedSample) -> Void

    init?(width: Int32, height: Int32, onEncodedFrame: @escaping (TimedSample) -> Void) {
        self.onEncodedFrame = onEncodedFrame

        func createSession(codecType: CMVideoCodecType) -> VTCompressionSession? {
            var newSession: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: codecType,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &newSession
            )
            guard status == noErr else {
                NSLog("%@", "Snapshot: VTCompressionSessionCreate failed for codec \(codecType) (\(status))")
                return nil
            }
            return newSession
        }

        // HEVC is ~30-50% more efficient than H.264 at the same visual
        // quality on the same hardware-accelerated path, but not every Mac
        // has a hardware HEVC encoder — fall back to H.264 if it's missing.
        var profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel
        var session = createSession(codecType: kCMVideoCodecType_HEVC)
        if session == nil {
            profileLevel = kVTProfileLevel_H264_High_AutoLevel
            session = createSession(codecType: kCMVideoCodecType_H264)
        }
        guard let session else {
            NSLog("%@", "Snapshot: failed to create a VTCompressionSession with any supported codec")
            return nil
        }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
        let bitrate = Settings.videoBitrate(width: Int(width), height: Int(height))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // DataRateLimits caps peak instantaneous rate so busy frames (particle-
        // heavy combat, fast camera pans) don't get starved relative to the
        // average — without this, VideoToolbox's rate control can let quality
        // sag noticeably during exactly the moments you'd want a clean clip.
        let bytesPerSecond = bitrate / 8
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [bytesPerSecond * 2, 1] as CFArray
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: Int(Double(Settings.frameRate) * Settings.keyframeIntervalSeconds) as CFNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: Settings.keyframeIntervalSeconds as CFNumber
        )
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = sampleBuffer.presentationTimeStamp

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [onEncodedFrame] status, _, encodedBuffer in
            guard status == noErr, let encodedBuffer, CMSampleBufferDataIsReady(encodedBuffer) else { return }
            let isKeyframe = Self.isSyncSample(encodedBuffer)
            onEncodedFrame(TimedSample(sampleBuffer: encodedBuffer, isKeyframe: isKeyframe))
        }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
            let notSync = attachmentsArray.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool
        else {
            // Absence of the key means it IS a sync sample (keyframe).
            return true
        }
        return !notSync
    }
}
