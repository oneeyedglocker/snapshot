import AVFoundation
import CoreMedia
import Foundation

enum ExportError: Error {
    case noVideoSamples
    case writerFailed(String)
}

/// Muxes a slice of the ring buffer into an .mp4. Video samples are already
/// encoded (HEVC, or H.264 as a fallback — see VideoEncoder), so they're
/// appended passthrough (no re-encoding, near instant). Audio is still raw
/// PCM, so AVAssetWriter encodes it to AAC here.
enum ClipExporter {
    static func export(video: [TimedSample], audio: [TimedSample], lengthSeconds: Double, to url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !video.isEmpty else {
            completion(.failure(ExportError.noVideoSamples))
            return
        }

        let latest = video[video.count - 1].presentationTime
        let cutoff = latest - CMTime(seconds: lengthSeconds, preferredTimescale: 600)

        // Walk back to the nearest keyframe at/before the cutoff so the clip
        // is decodable from frame one, even if that means it runs slightly
        // over the requested length.
        var startIndex = video.firstIndex { $0.presentationTime >= cutoff } ?? 0
        while startIndex > 0 && !video[startIndex].isKeyframe {
            startIndex -= 1
        }
        if !video[startIndex].isKeyframe, let firstKeyframe = video.firstIndex(where: { $0.isKeyframe }) {
            startIndex = firstKeyframe
        }

        let trimmedVideo = Array(video[startIndex...])
        guard let clipStart = trimmedVideo.first?.presentationTime,
              let videoFormat = trimmedVideo.first?.sampleBuffer.formatDescription else {
            completion(.failure(ExportError.noVideoSamples))
            return
        }
        let trimmedAudio = audio.filter { $0.presentationTime >= clipStart }
        NSLog(
            "%@",
            "Snapshot: export audio: \(audio.count) buffered total (first=\(audio.first.map { CMTimeGetSeconds($0.presentationTime) }.map(String.init) ?? "n/a"), "
            + "last=\(audio.last.map { CMTimeGetSeconds($0.presentationTime) }.map(String.init) ?? "n/a")), clipStart=\(CMTimeGetSeconds(clipStart)), "
            + "trimmedAudio=\(trimmedAudio.count)"
        )

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else {
                completion(.failure(ExportError.writerFailed("cannot add video input")))
                return
            }
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if !trimmedAudio.isEmpty {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Settings.audioSampleRate,
                    AVNumberOfChannelsKey: Settings.audioChannels,
                    AVEncoderBitRateKey: 128_000
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                } else {
                    NSLog("%@", "Snapshot: writer.canAdd(audioInput) returned false, clip will be silent")
                }
            } else {
                NSLog("%@", "Snapshot: trimmedAudio is empty, clip will be silent")
            }

            guard writer.startWriting() else {
                completion(.failure(writer.error ?? ExportError.writerFailed("startWriting failed")))
                return
            }
            writer.startSession(atSourceTime: clipStart)

            let writeQueue = DispatchQueue(label: "snapshot.export")
            var videoIndex = 0
            var audioIndex = 0
            let group = DispatchGroup()

            group.enter()
            videoInput.requestMediaDataWhenReady(on: writeQueue) {
                while videoInput.isReadyForMoreMediaData {
                    guard videoIndex < trimmedVideo.count else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    videoInput.append(trimmedVideo[videoIndex].sampleBuffer)
                    videoIndex += 1
                }
            }

            if let audioInput {
                group.enter()
                audioInput.requestMediaDataWhenReady(on: writeQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard audioIndex < trimmedAudio.count else {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        audioInput.append(trimmedAudio[audioIndex].sampleBuffer)
                        audioIndex += 1
                    }
                }
            }

            group.notify(queue: writeQueue) {
                writer.finishWriting {
                    if writer.status == .completed {
                        completion(.success(url))
                    } else {
                        completion(.failure(writer.error ?? ExportError.writerFailed("finishWriting ended in status \(writer.status.rawValue)")))
                    }
                }
            }
        } catch {
            completion(.failure(error))
        }
    }
}
