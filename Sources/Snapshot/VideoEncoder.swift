import CoreMedia
import Foundation
import VideoToolbox

/// Wraps a VTCompressionSession to turn raw captured frames into H.264, one
/// frame at a time, in real time. We disable frame reordering so decode order
/// always matches display order — that keeps the ring-buffer/export logic
/// (which just slices a contiguous array of encoded samples) simple and correct.
final class VideoEncoder {
    private var session: VTCompressionSession?
    private let onEncodedFrame: (TimedSample) -> Void

    init?(width: Int32, height: Int32, onEncodedFrame: @escaping (TimedSample) -> Void) {
        self.onEncodedFrame = onEncodedFrame

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard status == noErr, let session = newSession else {
            print("Snapshot: failed to create VTCompressionSession (\(status))")
            return nil
        }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: Settings.videoBitrate as CFNumber)
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

        VTCompressionSessionEncodeFrameWithOutputHandler(
            session,
            imageBuffer,
            pts,
            .invalid,
            nil,
            nil
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
