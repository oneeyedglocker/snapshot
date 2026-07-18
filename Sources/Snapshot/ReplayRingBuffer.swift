import CoreMedia
import Foundation

struct TimedSample {
    let sampleBuffer: CMSampleBuffer
    let presentationTime: CMTime
    let isKeyframe: Bool

    init(sampleBuffer: CMSampleBuffer, isKeyframe: Bool) {
        self.sampleBuffer = sampleBuffer
        self.presentationTime = sampleBuffer.presentationTimeStamp
        self.isKeyframe = isKeyframe
    }
}

/// Time-windowed buffer of encoded (video) or raw (audio) sample buffers.
/// Anything older than `windowSeconds` relative to the newest sample is dropped
/// on every append, so memory stays bounded no matter how long capture runs.
actor ReplayRingBuffer {
    private var samples: [TimedSample] = []
    private let windowSeconds: Double

    init(windowSeconds: Double) {
        self.windowSeconds = windowSeconds
    }

    func append(_ sample: TimedSample) {
        samples.append(sample)
        prune()
    }

    private func prune() {
        guard let newest = samples.last?.presentationTime else { return }
        let cutoff = newest - CMTime(seconds: windowSeconds, preferredTimescale: 600)
        // Samples are appended in presentation order, so the buffer stays sorted;
        // drop from the front until we're back inside the window.
        var dropCount = 0
        for sample in samples {
            if sample.presentationTime < cutoff {
                dropCount += 1
            } else {
                break
            }
        }
        if dropCount > 0 {
            samples.removeFirst(dropCount)
        }
    }

    func snapshot() -> [TimedSample] {
        samples
    }

    func reset() {
        samples.removeAll()
    }
}
