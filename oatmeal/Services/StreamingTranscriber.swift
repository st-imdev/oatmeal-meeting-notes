@preconcurrency import AVFoundation
import FluidAudio
import os

/// Audio chunk paired with the transcript segment it produced,
/// used for offline re-diarization after recording ends.
struct SpeechChunkRecord: Sendable {
    let samples: [Float]
    let segmentID: UUID
}

/// Consumes an audio buffer stream, detects speech via Silero VAD,
/// and transcribes completed speech segments via Parakeet-TDT.
/// Optionally runs speaker diarization on system audio to identify
/// distinct speakers (Speaker 2, Speaker 3, etc.).
final class StreamingTranscriber: @unchecked Sendable {
    private let asrManager: AsrManager
    private let vadManager: VadManager
    private let source: TranscriptSource
    private let diarizer: DiarizerManager?
    private let onSegment: @Sendable (TranscriptSegment) -> Void
    private let log = Logger(subsystem: "wonderwhat.openola", category: "StreamingTranscriber")

    /// Resampler from source format to 16kHz mono Float32.
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Running timestamp offset so segments get wall-clock relative times.
    private let sessionStartedAt: Date

    /// Maps diarizer speaker IDs to display labels.
    private var speakerLabelMap: [String: String] = [:]
    private var nextSpeakerNumber = 2

    /// Speech chunks saved for offline re-diarization (speaker audio only).
    private(set) var speechChunks: [SpeechChunkRecord] = []

    init(
        asrManager: AsrManager,
        vadManager: VadManager,
        source: TranscriptSource,
        sessionStartedAt: Date,
        diarizer: DiarizerManager? = nil,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void
    ) {
        self.asrManager = asrManager
        self.vadManager = vadManager
        self.source = source
        self.sessionStartedAt = sessionStartedAt
        self.diarizer = diarizer
        self.onSegment = onSegment
    }

    /// Silero VAD expects chunks of 4096 samples (256ms at 16kHz).
    private static let vadChunkSize = 4096
    /// Flush speech for transcription every ~3 seconds (48,000 samples at 16kHz).
    private static let flushInterval = 48_000

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var isSpeaking = false

        for await buffer in stream {
            guard let samples = extractSamples(buffer) else { continue }
            vadBuffer.append(contentsOf: samples)

            while vadBuffer.count >= Self.vadChunkSize {
                let chunk = Array(vadBuffer.prefix(Self.vadChunkSize))
                vadBuffer.removeFirst(Self.vadChunkSize)

                do {
                    let result = try await vadManager.processStreamingChunk(
                        chunk,
                        state: vadState,
                        config: .default,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    vadState = result.state

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            isSpeaking = true
                            speechSamples.removeAll(keepingCapacity: true)

                        case .speechEnd:
                            isSpeaking = false
                            if speechSamples.count > 8000 {
                                let segment = speechSamples
                                speechSamples.removeAll(keepingCapacity: true)
                                await transcribeSegment(segment)
                            } else {
                                speechSamples.removeAll(keepingCapacity: true)
                            }
                        }
                    }

                    if isSpeaking {
                        speechSamples.append(contentsOf: chunk)

                        // Flush every ~3s for near-real-time output during continuous speech
                        if speechSamples.count >= Self.flushInterval {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(segment)
                        }
                    }
                } catch {
                    log.error("VAD error: \(error.localizedDescription)")
                }
            }
        }

        // Flush remaining speech at end of stream
        if speechSamples.count > 8000 {
            await transcribeSegment(speechSamples)
        }
    }

    private func transcribeSegment(_ samples: [Float]) async {
        do {
            let result = try await asrManager.transcribe(samples)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            let timestamp = Date().timeIntervalSince(sessionStartedAt)
            let speaker = identifySpeaker(in: samples) ?? source.speakerLabel

            let segment = TranscriptSegment(
                text: text,
                timestamp: timestamp,
                speaker: speaker
            )

            // Save speech chunk for offline re-diarization (speaker audio only)
            if diarizer != nil {
                speechChunks.append(SpeechChunkRecord(samples: samples, segmentID: segment.id))
            }

            onSegment(segment)
        } catch {
            log.error("ASR error: \(error.localizedDescription)")
        }
    }

    /// Run diarization on a speech segment to identify which speaker it belongs to.
    /// Returns a stable label like "Speaker 2", "Speaker 3", etc.
    private func identifySpeaker(in samples: [Float]) -> String? {
        guard let diarizer, samples.count > 4000 else { return nil }

        do {
            let result = try diarizer.performCompleteDiarization(samples)
            // Pick the speaker with the longest total duration in this segment.
            guard let dominant = dominantSpeaker(in: result.segments) else { return nil }
            return displayLabel(for: dominant)
        } catch {
            log.error("Diarization error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Find the speaker ID with the most total speech time in the segment.
    private func dominantSpeaker(in segments: [TimedSpeakerSegment]) -> String? {
        var durations: [String: Float] = [:]
        for seg in segments {
            durations[seg.speakerId, default: 0] += seg.durationSeconds
        }
        return durations.max(by: { $0.value < $1.value })?.key
    }

    /// Map a diarizer speaker ID to a stable "Speaker N" display label.
    private func displayLabel(for speakerID: String) -> String {
        if let existing = speakerLabelMap[speakerID] {
            return existing
        }
        let label = "Speaker \(nextSpeakerNumber)"
        nextSpeakerNumber += 1
        speakerLabelMap[speakerID] = label
        return label
    }

    /// Extract [Float] samples from an AVAudioPCMBuffer, resampling to 16kHz mono if needed.
    private func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        // Fast path: already Float32 at 16kHz
        if sourceFormat.commonFormat == .pcmFormatFloat32 && sourceFormat.sampleRate == 16000 {
            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        // Slow path: resample via AVAudioConverter
        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrames > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("Resample error: \(error.localizedDescription)")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }
}
