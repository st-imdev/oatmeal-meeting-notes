@preconcurrency import AVFoundation
import CoreMedia
import FluidAudio
import Foundation
import os

/// Meeting transcription backend powered by FluidAudio (Parakeet-TDT ASR + Silero VAD).
/// Runs entirely on-device — no network required after the initial ~600MB model download.
/// Ported from the OpenGranola transcription pipeline.
final class FluidAudioRecorder: MeetingTranscriptionBackend, @unchecked Sendable {
    var onUpdate: ((TranscriptionResult) -> Void)?
    var onStatus: ((String) -> Void)?
    var preferredMicrophoneUID: String?

    /// Reports model download progress: (fractionCompleted 0…1, phaseDescription).
    /// Only fires during the first-run model download.
    var onDownloadProgress: (@Sendable (Double, String) -> Void)?

    private let log = Logger(subsystem: "wonderwhat.openola", category: "FluidAudioRecorder")
    private let stateQueue = DispatchQueue(label: "wonderwhat.openola.fluid-audio-recorder-state")

    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var diarizer: DiarizerManager?
    private var sessionStartedAt = Date()

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?
    private var micEngine: AVAudioEngine?
    private var micContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var systemAudioCapture: SystemAudioCapture?
    private var sysContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var speakerTranscriber: StreamingTranscriber?

    private var segments: [TranscriptSegment] = []
    private(set) var latestResult = TranscriptionResult(transcript: "", segments: [])

    func availableMicrophones() -> [MicrophoneDevice] {
        SpeechRecorder.availableMicrophones()
    }

    func start() async throws {
        guard await SpeechRecorder.requestMicrophonePermission() else {
            throw SpeechRecorderError.microphonePermissionDenied
        }

        // Load FluidAudio models (downloads ~600MB on first run)
        if asrManager == nil || vadManager == nil {
            onStatus?("Loading speech model (~600 MB on first run)…")
            do {
                let progressCallback = onDownloadProgress
                let models = try await AsrModels.downloadAndLoad(version: .v2) { progress in
                    let phase: String
                    switch progress.phase {
                    case .listing:
                        phase = "Checking model files…"
                    case .downloading(let completed, let total):
                        phase = "Downloading model (\(completed)/\(total) files)…"
                    case .compiling(let name):
                        phase = "Compiling \(name)…"
                    }
                    progressCallback?(progress.fractionCompleted, phase)
                }

                onDownloadProgress?(1.0, "Initializing speech engine…")
                onStatus?("Initializing speech engine…")
                let asr = AsrManager(config: .default)
                try await asr.initialize(models: models)
                self.asrManager = asr

                let vad = try await VadManager()
                self.vadManager = vad

                // Load speaker diarization models for speaker identification
                onDownloadProgress?(0.9, "Loading speaker identification model…")
                onStatus?("Loading speaker identification model…")
                let diarizerModels = try await DiarizerModels.download()
                let diaConfig = DiarizerConfig(
                    clusteringThreshold: 0.85  // Higher than default 0.7 to reduce speaker merging
                )
                let dia = DiarizerManager(config: diaConfig)
                dia.initialize(models: diarizerModels)
                self.diarizer = dia

                onDownloadProgress?(1.0, "Ready")
                onStatus?("Speech model ready.")
            } catch {
                onDownloadProgress?(0, "Failed")
                throw SpeechRecorderError.speechProcessingFailure(
                    "Failed to load Parakeet-TDT model: \(error.localizedDescription)"
                )
            }
        }

        guard let asrManager, let vadManager else {
            throw SpeechRecorderError.speechProcessingFailure("Speech models failed to initialize.")
        }

        resetSessionState()

        // --- Microphone capture via AVAudioEngine ---
        //
        // IMPORTANT — Bluetooth HFP compatibility (AirPods etc.)
        // -------------------------------------------------------
        // DO NOT use `format: nil` in installTap(). Bluetooth HFP devices run
        // at 24kHz but inputNode.outputFormat may report 48kHz, causing a
        // silent format mismatch where the tap never fires.
        //
        // Instead, read the input node's format and build a standard PCM
        // format with matching sample rate + channels. This lets AVAudioEngine
        // handle any necessary conversion internally.
        //
        // This pattern is from OpenOats (github.com/yazinsai/OpenOats) and
        // works reliably across built-in mics, USB, and Bluetooth devices.
        // -------------------------------------------------------
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Only explicitly route when the user selected a specific mic.
        // For the system default, let AVAudioEngine handle device selection
        // implicitly — explicitly routing to a Bluetooth default device
        // via AudioUnitSetProperty can break HFP format negotiation.
        if let uid = preferredMicrophoneUID {
            try SpeechRecorder.route(inputNode: inputNode, toMicrophoneUID: uid)
        }

        let micFormat = inputNode.outputFormat(forBus: 0)

        guard micFormat.sampleRate > 0 && micFormat.channelCount > 0 else {
            throw SpeechRecorderError.microphoneConfigurationFailure(
                "Invalid mic format: sr=\(micFormat.sampleRate) ch=\(micFormat.channelCount)"
            )
        }

        let micStream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.micContinuation = continuation
        }

        let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: micFormat.sampleRate,
            channels: micFormat.channelCount
        )
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            self.micContinuation?.yield(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw SpeechRecorderError.audioEngineFailure
        }
        self.micEngine = engine

        // Start mic transcription
        let micTranscriber = StreamingTranscriber(
            asrManager: asrManager,
            vadManager: vadManager,
            source: .microphone,
            sessionStartedAt: sessionStartedAt,
            onSegment: { [weak self] segment in
                self?.appendSegment(segment)
            }
        )
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }

        // --- Speaker capture via ScreenCaptureKit (best-effort) ---
        if SpeechRecorder.requestScreenCapturePermission() {
            do {
                let sysStream = AsyncStream<AVAudioPCMBuffer> { continuation in
                    self.sysContinuation = continuation
                }

                let capture = SystemAudioCapture(
                    bundleIdentifier: Bundle.main.bundleIdentifier
                ) { [weak self] sampleBuffer in
                    guard let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer) else { return }
                    self?.sysContinuation?.yield(pcmBuffer)
                } onError: { [weak self] error in
                    self?.onStatus?("Speaker capture stopped: \(error.localizedDescription)")
                }

                try await capture.start()
                self.systemAudioCapture = capture

                let sysTranscriber = StreamingTranscriber(
                    asrManager: asrManager,
                    vadManager: vadManager,
                    source: .speaker,
                    sessionStartedAt: sessionStartedAt,
                    diarizer: diarizer,
                    onSegment: { [weak self] segment in
                        self?.appendSegment(segment)
                    }
                )
                self.speakerTranscriber = sysTranscriber
                sysTask = Task.detached {
                    await sysTranscriber.run(stream: sysStream)
                }

                onStatus?("Recording microphone and speaker audio. Transcribing with Parakeet-TDT.")
            } catch {
                onStatus?("Speaker capture unavailable — recording microphone only. (\(error.localizedDescription))")
            }
        } else {
            onStatus?("Screen capture permission not granted — recording microphone only.")
        }

        if systemAudioCapture != nil && sysTask != nil {
            onStatus?("Recording microphone and speaker audio. Transcribing with Parakeet-TDT.")
        }
    }

    func finish() async -> TranscriptionResult {
        onStatus?("Finalizing transcript…")

        // Stop audio input feeds
        micContinuation?.finish()
        micContinuation = nil
        sysContinuation?.finish()
        sysContinuation = nil

        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            micEngine = nil
        }

        if let capture = systemAudioCapture {
            await capture.stop()
            systemAudioCapture = nil
        }

        // Wait for transcription tasks to drain
        await micTask?.value
        await sysTask?.value
        micTask = nil
        sysTask = nil

        // Re-diarize speaker audio with full context for better speaker separation
        offlineRediarize()
        speakerTranscriber = nil

        onStatus?("Capture stopped.")
        return stateQueue.sync { latestResult }
    }

    func transcribeFile(at url: URL) async throws -> TranscriptionResult {
        // Fall back to Apple Speech for file transcription since FluidAudio
        // is optimized for streaming.
        let fallback = SpeechRecorder()
        fallback.onStatus = onStatus
        return try await fallback.transcribeFile(at: url)
    }

    // MARK: - Private

    private func resetSessionState() {
        sessionStartedAt = Date()
        speakerTranscriber = nil
        stateQueue.sync {
            segments = []
            latestResult = TranscriptionResult(transcript: "", segments: [])
        }
    }

    /// Re-diarize all speaker audio with full meeting context.
    /// Running diarization on the complete audio (vs per-chunk) gives the model
    /// enough signal to reliably distinguish speakers.
    private func offlineRediarize() {
        guard let speakerTranscriber,
              let diarizer,
              speakerTranscriber.speechChunks.count > 1 else { return }

        let chunks = speakerTranscriber.speechChunks
        let allSamples = chunks.flatMap(\.samples)
        guard allSamples.count > 16000 else { return } // Need >1s of audio

        onStatus?("Improving speaker labels…")

        do {
            let result = try diarizer.performCompleteDiarization(allSamples)

            // Build new stable label map from offline speaker IDs
            var newLabelMap: [String: String] = [:]
            var nextSpeakerNum = 2

            // For each original chunk, find which offline speaker is dominant
            // at the chunk's midpoint in the concatenated audio timeline
            var sampleOffset: Float = 0
            for chunk in chunks {
                let chunkDuration = Float(chunk.samples.count) / 16000.0
                let chunkMid = sampleOffset + chunkDuration / 2.0

                // Find speaker active at chunk midpoint
                let speaker = dominantSpeakerAt(
                    time: chunkMid,
                    in: result.segments
                )

                if let speakerId = speaker {
                    if newLabelMap[speakerId] == nil {
                        newLabelMap[speakerId] = "Speaker \(nextSpeakerNum)"
                        nextSpeakerNum += 1
                    }
                    let label = newLabelMap[speakerId]!

                    stateQueue.sync {
                        if let idx = segments.firstIndex(where: { $0.id == chunk.segmentID }) {
                            segments[idx].speaker = label
                        }
                    }
                }

                sampleOffset += chunkDuration
            }

            // Rebuild the combined result with updated labels
            stateQueue.sync {
                let sorted = segments.sorted {
                    ($0.timestamp ?? .greatestFiniteMagnitude) < ($1.timestamp ?? .greatestFiniteMagnitude)
                }
                segments = sorted
                let transcript = sorted.map(\.renderedLine).joined(separator: "\n")
                latestResult = TranscriptionResult(transcript: transcript, segments: sorted)
            }

            log.info("Offline re-diarization complete: \(newLabelMap.count) speakers identified from \(chunks.count) chunks")
        } catch {
            log.error("Offline re-diarization failed: \(error.localizedDescription)")
        }
    }

    /// Find the speaker active at a given time (seconds) in diarization results.
    private func dominantSpeakerAt(time: Float, in segments: [TimedSpeakerSegment]) -> String? {
        // TimedSpeakerSegment has timing info — find the segment containing this time.
        // Try startSeconds first; fall back to cumulative duration if needed.
        var cumulative: Float = 0
        for seg in segments {
            let segEnd = cumulative + seg.durationSeconds
            if time >= cumulative && time < segEnd {
                return seg.speakerId
            }
            cumulative = segEnd
        }
        return nil
    }

    private func appendSegment(_ segment: TranscriptSegment) {
        let merged = stateQueue.sync { () -> TranscriptionResult in
            segments.append(segment)

            let sorted = segments.sorted {
                ($0.timestamp ?? .greatestFiniteMagnitude) < ($1.timestamp ?? .greatestFiniteMagnitude)
            }
            segments = sorted

            let transcript = sorted
                .map(\.renderedLine)
                .joined(separator: "\n")

            latestResult = TranscriptionResult(transcript: transcript, segments: sorted)
            return latestResult
        }

        onUpdate?(merged)
    }

    /// Convert a CMSampleBuffer from ScreenCaptureKit into an AVAudioPCMBuffer.
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        var asbd = streamDescription.pointee
        let format = withUnsafePointer(to: &asbd) { pointer in
            AVAudioFormat(streamDescription: pointer)
        }

        guard let format else { return nil }

        let frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: asbd.mChannelsPerFrame,
                mDataByteSize: 0,
                mData: nil
            )
        )

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }

        pcmBuffer.frameLength = frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData
            else {
                continue
            }

            memcpy(destination, source, Int(sourceBuffers[index].mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        _ = blockBuffer
        return pcmBuffer
    }
}
