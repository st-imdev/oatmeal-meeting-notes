@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

@available(macOS 26.0, *)
final class SpeechAnalyzerRecorder: MeetingTranscriptionBackend, @unchecked Sendable {
    var onUpdate: ((TranscriptionResult) -> Void)?
    var onStatus: ((String) -> Void)?
    var preferredMicrophoneUID: String?

    private let audioEngine = AVAudioEngine()
    private let locale: Locale
    private let stateQueue = DispatchQueue(label: "wonderwhat.openola.speech-analyzer-recorder-state")

    private var sessionStartedAt = Date()
    private var microphoneAnalyzer: SourceAnalyzer?
    private var speakerAnalyzer: SourceAnalyzer?
    private var systemAudioCapture: SystemAudioCapture?
    private var sourceStates: [TranscriptSource: [TranscriptSegment]] = [:]
    private(set) var latestResult = TranscriptionResult(transcript: "", segments: [])

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func availableMicrophones() -> [MicrophoneDevice] {
        SpeechRecorder.availableMicrophones()
    }

    func start() async throws {
        guard await SpeechRecorder.requestMicrophonePermission() else {
            throw SpeechRecorderError.microphonePermissionDenied
        }

        guard await SpeechRecorder.requestSpeechPermission() else {
            throw SpeechRecorderError.speechPermissionDenied
        }

        guard SpeechTranscriber.isAvailable else {
            throw SpeechRecorderError.speechProcessingFailure("Apple's on-device transcriber is unavailable on this Mac.")
        }

        await cancelActiveCapture(statusMessage: nil)
        resetSessionState()

        do {
            let inputNode = audioEngine.inputNode
            try SpeechRecorder.route(inputNode: inputNode, toMicrophoneUID: preferredMicrophoneUID)
            let microphoneFormat = inputNode.inputFormat(forBus: 0)

            let microphoneAnalyzer = try await makeSourceAnalyzer(
                source: .microphone,
                naturalFormat: microphoneFormat,
                initialOffset: Date().timeIntervalSince(sessionStartedAt)
            )
            try startMicrophoneFeed(using: microphoneAnalyzer, inputNode: inputNode, format: microphoneFormat)
            self.microphoneAnalyzer = microphoneAnalyzer
        } catch {
            await cancelActiveCapture(statusMessage: nil)
            throw error
        }

        // Speaker capture is best-effort — if screen capture permission is denied
        // or system audio fails, continue with microphone only.
        if SpeechRecorder.requestScreenCapturePermission() {
            do {
                let speakerAnalyzer = try await makeSourceAnalyzer(
                    source: .speaker,
                    naturalFormat: nil,
                    initialOffset: Date().timeIntervalSince(sessionStartedAt)
                )
                try await startSpeakerFeed(using: speakerAnalyzer)
                self.speakerAnalyzer = speakerAnalyzer
            } catch {
                onStatus?("Speaker capture unavailable — recording microphone only. (\(error.localizedDescription))")
            }
        } else {
            onStatus?("Screen capture permission not granted — recording microphone only.")
        }

        if speakerAnalyzer != nil {
            onStatus?("Recording your microphone and speaker audio. Transcript is updating live.")
        }
    }

    func finish() async -> TranscriptionResult {
        onStatus?("Finalizing transcript…")

        await stopInputFeeds()

        let microphoneSegments = await microphoneAnalyzer?.finish() ?? []
        let speakerSegments = await speakerAnalyzer?.finish() ?? []
        microphoneAnalyzer = nil
        speakerAnalyzer = nil

        publish(segments: microphoneSegments, for: .microphone)
        publish(segments: speakerSegments, for: .speaker)

        let result = stateQueue.sync { latestResult }
        onUpdate?(result)
        onStatus?("Capture stopped.")
        return result
    }

    func transcribeFile(at url: URL) async throws -> TranscriptionResult {
        let fallback = SpeechRecorder(locale: locale)
        fallback.onStatus = onStatus
        return try await fallback.transcribeFile(at: url)
    }

    private func resetSessionState() {
        sessionStartedAt = Date()
        stateQueue.sync {
            latestResult = TranscriptionResult(transcript: "", segments: [])
            sourceStates = [
                .microphone: [],
                .speaker: []
            ]
        }
    }

    private func makeSourceAnalyzer(
        source: TranscriptSource,
        naturalFormat: AVAudioFormat?,
        initialOffset: TimeInterval
    ) async throws -> SourceAnalyzer {
        let analyzer = SourceAnalyzer(
            source: source,
            locale: locale,
            statusHandler: { [weak self] message in
                self?.onStatus?(message)
            },
            updateHandler: { [weak self] source, segments in
                self?.publish(segments: segments, for: source)
            }
        )

        try await analyzer.start(naturalFormat: naturalFormat, initialOffset: initialOffset)
        return analyzer
    }

    private func startMicrophoneFeed(
        using analyzer: SourceAnalyzer,
        inputNode: AVAudioInputNode,
        format _: AVAudioFormat
    ) throws {
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            analyzer.appendMicrophoneBuffer(buffer)
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            throw SpeechRecorderError.audioEngineFailure
        }
    }

    private func startSpeakerFeed(using analyzer: SourceAnalyzer) async throws {
        let capture = SystemAudioCapture(bundleIdentifier: Bundle.main.bundleIdentifier) { sampleBuffer in
            analyzer.appendSpeakerSampleBuffer(sampleBuffer)
        } onError: { [weak self] error in
            self?.onStatus?("Speaker capture stopped: \(error.localizedDescription)")
        }

        do {
            try await capture.start()
            systemAudioCapture = capture
        } catch let recorderError as SpeechRecorderError {
            throw recorderError
        } catch {
            throw SpeechRecorderError.systemAudioCaptureFailure(error.localizedDescription)
        }
    }

    private func stopInputFeeds() async {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        if let systemAudioCapture {
            await systemAudioCapture.stop()
            self.systemAudioCapture = nil
        }
    }

    private func cancelActiveCapture(statusMessage: String?) async {
        await stopInputFeeds()
        await microphoneAnalyzer?.cancel()
        await speakerAnalyzer?.cancel()
        microphoneAnalyzer = nil
        speakerAnalyzer = nil

        if let statusMessage {
            onStatus?(statusMessage)
        }
    }

    private func publish(segments: [TranscriptSegment], for source: TranscriptSource) {
        let merged = stateQueue.sync {
            sourceStates[source] = segments
            latestResult = Self.merge(sourceStates: sourceStates)
            return latestResult
        }

        onUpdate?(merged)
    }

    private static func merge(sourceStates: [TranscriptSource: [TranscriptSegment]]) -> TranscriptionResult {
        let speakerOrder: [String: Int] = [
            TranscriptSource.microphone.speakerLabel: 0,
            TranscriptSource.speaker.speakerLabel: 1
        ]

        let mergedSegments = sourceStates
            .values
            .flatMap { $0 }
            .sorted { lhs, rhs in
                let leftTime = lhs.timestamp ?? .greatestFiniteMagnitude
                let rightTime = rhs.timestamp ?? .greatestFiniteMagnitude

                if leftTime == rightTime {
                    let leftRank = speakerOrder[lhs.speaker ?? ""] ?? 0
                    let rightRank = speakerOrder[rhs.speaker ?? ""] ?? 0
                    if leftRank == rightRank {
                        return lhs.text < rhs.text
                    }
                    return leftRank < rightRank
                }

                return leftTime < rightTime
            }

        let compacted = compact(segments: mergedSegments)
        let transcript = compacted
            .map(\.renderedLine)
            .joined(separator: "\n")

        return TranscriptionResult(transcript: transcript, segments: compacted)
    }

    private static func compact(segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var compacted: [TranscriptSegment] = []

        for segment in segments {
            let trimmedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                continue
            }

            if var last = compacted.last,
               last.speaker == segment.speaker,
               let lastTimestamp = last.timestamp,
               let currentTimestamp = segment.timestamp,
               currentTimestamp - lastTimestamp < 1.4 {
                last.text = joinTranscriptText(last.text, trimmedText)
                compacted[compacted.count - 1] = last
            } else {
                var cleaned = segment
                cleaned.text = trimmedText
                compacted.append(cleaned)
            }
        }

        return compacted
    }

    private static func joinTranscriptText(_ lhs: String, _ rhs: String) -> String {
        let trimmedLHS = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRHS = rhs.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLHS.isEmpty else {
            return trimmedRHS
        }

        guard !trimmedRHS.isEmpty else {
            return trimmedLHS
        }

        let separators = CharacterSet(charactersIn: ".,!?;:")
        if let firstScalar = trimmedRHS.unicodeScalars.first, separators.contains(firstScalar) {
            return trimmedLHS + trimmedRHS
        }

        return trimmedLHS + " " + trimmedRHS
    }
}

@available(macOS 26.0, *)
private final class SourceAnalyzer: @unchecked Sendable {
    private final class PendingBuffer: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private let source: TranscriptSource
    private let locale: Locale
    private let statusHandler: (String) -> Void
    private let updateHandler: (TranscriptSource, [TranscriptSegment]) -> Void
    private let queue: DispatchQueue

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var analysisTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Error>?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSignature: String?
    private var latestSegments: [TranscriptSegment] = []
    private var nextBufferStartTime = CMTime.zero

    init(
        source: TranscriptSource,
        locale: Locale,
        statusHandler: @escaping (String) -> Void,
        updateHandler: @escaping (TranscriptSource, [TranscriptSegment]) -> Void
    ) {
        self.source = source
        self.locale = locale
        self.statusHandler = statusHandler
        self.updateHandler = updateHandler
        self.queue = DispatchQueue(label: "wonderwhat.openola.source-analyzer.\(source.rawValue)")
    }

    func start(naturalFormat: AVAudioFormat?, initialOffset: TimeInterval) async throws {
        let resolvedLocale = try await Self.resolveLocale(preferred: locale)
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [.etiquetteReplacements],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        let modules: [any SpeechModule] = [transcriber]

        try await Self.ensureAssets(for: modules, source: source, statusHandler: statusHandler)

        let compatibleFormats = await transcriber.availableCompatibleAudioFormats
        let targetFormat = await Self.chooseTargetFormat(
            naturalFormat: naturalFormat,
            compatibleFormats: compatibleFormats,
            modules: modules
        )

        guard let targetFormat else {
            throw SpeechRecorderError.speechProcessingFailure("Oatmeal could not find a compatible format for \(source.permissionName) audio.")
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: .init(priority: .userInitiated, modelRetention: .whileInUse)
        )

        let stream = AsyncThrowingStream<AnalyzerInput, Error> { continuation in
            self.inputContinuation = continuation
        }

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.targetFormat = targetFormat
        self.nextBufferStartTime = CMTime(seconds: initialOffset, preferredTimescale: 600)
        self.latestSegments = []
        self.converter = nil
        self.converterSignature = nil

        try await analyzer.prepareToAnalyze(in: targetFormat)

        analysisTask = Task {
            try await analyzer.start(inputSequence: stream)
        }

        resultsTask = Task { [weak self] in
            guard let self else {
                return
            }

            for try await result in transcriber.results {
                self.consume(result: result)
            }
        }
    }

    func appendMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let copiedBuffer = Self.copy(buffer) else {
            return
        }

        enqueue(buffer: copiedBuffer)
    }

    func appendSpeakerSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer = Self.makePCMBuffer(from: sampleBuffer) else {
            return
        }

        enqueue(buffer: buffer)
    }

    func finish() async -> [TranscriptSegment] {
        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                statusHandler("\(source.permissionName.capitalized) transcription stopped: \(error.localizedDescription)")
            }
        }

        do {
            try await analysisTask?.value
        } catch {
            statusHandler("\(source.permissionName.capitalized) transcription stopped: \(error.localizedDescription)")
        }

        do {
            try await resultsTask?.value
        } catch {
            statusHandler("\(source.permissionName.capitalized) transcription stopped: \(error.localizedDescription)")
        }

        analysisTask = nil
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        converterSignature = nil

        return queue.sync { latestSegments }
    }

    func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }

        analysisTask?.cancel()
        resultsTask?.cancel()

        analysisTask = nil
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        converterSignature = nil
    }

    private func enqueue(buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.appendOnQueue(buffer)
        }
    }

    private func appendOnQueue(_ buffer: AVAudioPCMBuffer) {
        guard let inputContinuation, let targetFormat else {
            return
        }

        do {
            let preparedBuffer = try convert(buffer, to: targetFormat)
            let startTime = nextBufferStartTime
            let duration = CMTime(
                seconds: Double(preparedBuffer.frameLength) / preparedBuffer.format.sampleRate,
                preferredTimescale: 600
            )
            nextBufferStartTime = CMTimeAdd(startTime, duration)
            inputContinuation.yield(AnalyzerInput(buffer: preparedBuffer, bufferStartTime: startTime))
        } catch {
            statusHandler("\(source.permissionName.capitalized) transcription stopped: \(error.localizedDescription)")
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputSignature = Self.signature(for: buffer.format)
        let targetSignature = Self.signature(for: targetFormat)

        if inputSignature == targetSignature {
            return buffer
        }

        if converter == nil || converterSignature != inputSignature {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterSignature = inputSignature
        }

        guard let converter else {
            throw SpeechRecorderError.speechProcessingFailure("Oatmeal could not create a converter for \(source.permissionName) audio.")
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw SpeechRecorderError.speechProcessingFailure("Oatmeal could not allocate a transcription buffer for \(source.permissionName) audio.")
        }

        var conversionError: NSError?
        let pendingBuffer = PendingBuffer(buffer: buffer)
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard let nextBuffer = pendingBuffer.buffer else {
                outStatus.pointee = .endOfStream
                return nil
            }

            pendingBuffer.buffer = nil
            outStatus.pointee = .haveData
            return nextBuffer
        }

        if let conversionError {
            throw conversionError
        }

        guard status == .haveData || status == .endOfStream else {
            throw SpeechRecorderError.speechProcessingFailure("Oatmeal could not convert \(source.permissionName) audio into the transcription format.")
        }

        return outputBuffer
    }

    private func consume(result: SpeechTranscriber.Result) {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.latestSegments = Self.replacingSegments(
                self.latestSegments,
                with: Self.map(result: result, source: self.source),
                in: result.range
            )
            self.updateHandler(self.source, self.latestSegments)
        }
    }

    private static func resolveLocale(preferred: Locale) async throws -> Locale {
        let candidates = [
            preferred,
            Locale(identifier: "en_GB"),
            Locale(identifier: "en_US")
        ]

        for candidate in candidates {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                return supported
            }
        }

        throw SpeechRecorderError.speechProcessingFailure("Oatmeal could not find a supported on-device locale for live transcription.")
    }

    private static func ensureAssets(
        for modules: [any SpeechModule],
        source: TranscriptSource,
        statusHandler: (String) -> Void
    ) async throws {
        let status = await AssetInventory.status(forModules: modules)

        switch status {
        case .installed:
            return
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                statusHandler("Installing on-device speech assets for \(source.permissionName) audio…")
                try await request.downloadAndInstall()
            }
        case .unsupported:
            throw SpeechRecorderError.speechProcessingFailure("On-device transcription is unavailable for the selected language on this Mac.")
        @unknown default:
            throw SpeechRecorderError.speechProcessingFailure("Oatmeal hit an unknown speech asset state for \(source.permissionName) audio.")
        }
    }

    private static func chooseTargetFormat(
        naturalFormat: AVAudioFormat?,
        compatibleFormats: [AVAudioFormat],
        modules: [any SpeechModule]
    ) async -> AVAudioFormat? {
        if let bestMatch = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: naturalFormat
        ) {
            return bestMatch
        }

        return compatibleFormats.sorted { lhs, rhs in
            let preferredSampleRate = naturalFormat?.sampleRate ?? 16_000

            if lhs.channelCount != rhs.channelCount {
                return lhs.channelCount < rhs.channelCount
            }

            let lhsDelta = abs(lhs.sampleRate - preferredSampleRate)
            let rhsDelta = abs(rhs.sampleRate - preferredSampleRate)
            if lhsDelta != rhsDelta {
                return lhsDelta < rhsDelta
            }

            return lhs.sampleRate < rhs.sampleRate
        }.first
    }

    private static func map(result: SpeechTranscriber.Result, source: TranscriptSource) -> [TranscriptSegment] {
        let segments = result.text.runs.compactMap { run -> TranscriptSegment? in
            let text = String(result.text[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                return nil
            }

            let timeRange = run.audioTimeRange ?? result.range
            let seconds = CMTimeGetSeconds(timeRange.start)
            let timestamp = seconds.isFinite ? seconds : nil

            return TranscriptSegment(
                text: text,
                timestamp: timestamp,
                speaker: source.speakerLabel
            )
        }

        if !segments.isEmpty {
            return segments
        }

        let fallbackText = String(result.text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackText.isEmpty else {
            return []
        }

        let seconds = CMTimeGetSeconds(result.range.start)
        let timestamp = seconds.isFinite ? seconds : nil
        return [
            TranscriptSegment(
                text: fallbackText,
                timestamp: timestamp,
                speaker: source.speakerLabel
            )
        ]
    }

    private static func replacingSegments(
        _ existingSegments: [TranscriptSegment],
        with replacementSegments: [TranscriptSegment],
        in timeRange: CMTimeRange
    ) -> [TranscriptSegment] {
        let start = CMTimeGetSeconds(timeRange.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange))
        let effectiveStart = start.isFinite ? start - 0.2 : -.greatestFiniteMagnitude
        let effectiveEnd = end.isFinite ? end + 0.2 : .greatestFiniteMagnitude

        let filteredSegments = existingSegments.filter { segment in
            guard let timestamp = segment.timestamp else {
                return false
            }

            return timestamp < effectiveStart || timestamp > effectiveEnd
        }

        return (filteredSegments + replacementSegments).sorted {
            ($0.timestamp ?? .greatestFiniteMagnitude) < ($1.timestamp ?? .greatestFiniteMagnitude)
        }
    }

    private static func signature(for format: AVAudioFormat) -> String {
        [
            String(format.channelCount),
            String(format.sampleRate),
            String(format.commonFormat.rawValue),
            format.isInterleaved ? "i" : "p"
        ].joined(separator: "|")
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }

        copiedBuffer.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData
            else {
                continue
            }

            memcpy(destination, source, Int(sourceBuffers[index].mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copiedBuffer
    }

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

        guard let format else {
            return nil
        }

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

        guard status == noErr else {
            return nil
        }

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
