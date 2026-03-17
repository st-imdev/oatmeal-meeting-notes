import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import Speech

struct TranscriptionResult: Sendable {
    var transcript: String
    var segments: [TranscriptSegment]
}

struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    let isSystemDefault: Bool

    var id: String { uid }

    var label: String {
        if isSystemDefault {
            return "\(name) (System Default)"
        }

        return name
    }
}

enum SpeechRecorderError: LocalizedError, Sendable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case screenCapturePermissionDenied
    case recognizerUnavailable(source: TranscriptSource)
    case noShareableDisplay
    case audioEngineFailure
    case microphoneConfigurationFailure(String)
    case systemAudioCaptureFailure(String)
    case speechProcessingFailure(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is denied. Allow Oatmeal to use the microphone in System Settings."
        case .speechPermissionDenied:
            return "Speech Recognition is denied. Allow Oatmeal to use Speech Recognition in System Settings."
        case .screenCapturePermissionDenied:
            return "Screen and system-audio capture is denied. Allow Oatmeal in System Settings so it can hear speaker output."
        case .recognizerUnavailable(let source):
            return "Speech recognition is unavailable for \(source.permissionName.lowercased()) audio right now."
        case .noShareableDisplay:
            return "Oatmeal could not find a display to attach speaker capture to."
        case .audioEngineFailure:
            return "The microphone audio engine could not start."
        case .microphoneConfigurationFailure(let message):
            return "The selected microphone could not be used. \(message)"
        case .systemAudioCaptureFailure(let message):
            return "System audio capture could not start. \(message)"
        case .speechProcessingFailure(let message):
            return "Speech processing could not start. \(message)"
        }
    }
}

enum TranscriptSource: String, CaseIterable, Sendable {
    case microphone
    case speaker

    var speakerLabel: String {
        switch self {
        case .microphone:
            return "Me"
        case .speaker:
            return "Them"
        }
    }

    var permissionName: String {
        switch self {
        case .microphone:
            return "microphone"
        case .speaker:
            return "speaker"
        }
    }
}

private struct SourceTranscriptState: Sendable {
    var segments: [TranscriptSegment] = []
}

private final class RecognitionHandle {
    let request: SFSpeechAudioBufferRecognitionRequest
    var task: SFSpeechRecognitionTask?

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }
}

final class SpeechRecorder: MeetingTranscriptionBackend, @unchecked Sendable {
    var onUpdate: ((TranscriptionResult) -> Void)?
    var onStatus: ((String) -> Void)?
    var preferredMicrophoneUID: String?

    private let audioEngine = AVAudioEngine()
    private let microphoneRecognizer: SFSpeechRecognizer?
    private let speakerRecognizer: SFSpeechRecognizer?
    private let stateQueue = DispatchQueue(label: "ai.codex.openola.speech-recorder-state")

    private var microphoneHandle: RecognitionHandle?
    private var speakerHandle: RecognitionHandle?
    private var systemAudioCapture: SystemAudioCapture?
    private var sessionStartedAt = Date()

    private var sourceStates: [TranscriptSource: SourceTranscriptState] = [:]
    private var sourceOffsets: [TranscriptSource: TimeInterval] = [:]
    private(set) var latestResult = TranscriptionResult(transcript: "", segments: [])

    init(locale: Locale = .current) {
        self.microphoneRecognizer = Self.makeRecognizer(preferred: locale)
        self.speakerRecognizer = Self.makeRecognizer(preferred: locale)
    }

    func start() async throws {
        guard await Self.requestMicrophonePermission() else {
            throw SpeechRecorderError.microphonePermissionDenied
        }

        guard await Self.requestSpeechPermission() else {
            throw SpeechRecorderError.speechPermissionDenied
        }

        guard let microphoneRecognizer, microphoneRecognizer.isAvailable else {
            throw SpeechRecorderError.recognizerUnavailable(source: .microphone)
        }

        await stopActiveCapture(statusMessage: nil)

        resetSessionState()

        let microphoneHandle = makeRecognitionHandle(
            source: .microphone,
            recognizer: microphoneRecognizer
        )
        self.microphoneHandle = microphoneHandle

        do {
            try startMicrophoneFeed(into: microphoneHandle.request)
        } catch {
            await stopActiveCapture(statusMessage: nil)
            throw error
        }

        // Speaker capture is best-effort — continue mic-only if it fails.
        if Self.requestScreenCapturePermission(),
           let speakerRecognizer, speakerRecognizer.isAvailable {
            do {
                let speakerHandle = makeRecognitionHandle(
                    source: .speaker,
                    recognizer: speakerRecognizer
                )
                try await startSpeakerFeed(into: speakerHandle.request)
                self.speakerHandle = speakerHandle
            } catch {
                onStatus?("Speaker capture unavailable — recording microphone only. (\(error.localizedDescription))")
            }
        } else {
            onStatus?("Speaker capture unavailable — recording microphone only.")
        }

        if speakerHandle != nil {
            onStatus?("Recording your microphone and speaker audio. Transcript is updating live.")
        }
    }

    func stop() {
        Task {
            await stopActiveCapture(statusMessage: "Meeting capture stopped.")
        }
    }

    func finish() async -> TranscriptionResult {
        onStatus?("Finalizing transcript…")

        await stopInputFeeds()
        endRecognitionRequests()

        try? await Task.sleep(for: .milliseconds(1200))

        cancelRecognitionTasks()
        onStatus?("Capture stopped.")

        return stateQueue.sync { latestResult }
    }

    func transcribeFile(at url: URL) async throws -> TranscriptionResult {
        guard await Self.requestSpeechPermission() else {
            throw SpeechRecorderError.speechPermissionDenied
        }

        guard let recognizer = Self.makeRecognizer(preferred: .current), recognizer.isAvailable else {
            throw SpeechRecorderError.recognizerUnavailable(source: .microphone)
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.taskHint = .dictation
        request.addsPunctuation = true

        onStatus?("Transcribing \(url.lastPathComponent)…")

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result, result.isFinal, !didResume {
                    didResume = true
                    let mapped = Self.mapFile(result: result)
                    self?.stateQueue.sync {
                        self?.latestResult = mapped
                    }
                    self?.onUpdate?(mapped)
                    continuation.resume(returning: mapped)
                } else if let error, !didResume {
                    didResume = true
                    continuation.resume(throwing: error)
                }
            }

            _ = task
        }
    }

    private func resetSessionState() {
        sessionStartedAt = Date()

        stateQueue.sync {
            latestResult = TranscriptionResult(transcript: "", segments: [])
            sourceStates = [:]
            sourceOffsets = [
                .microphone: 0,
                .speaker: 0
            ]
        }
    }

    private func makeRecognitionHandle(
        source: TranscriptSource,
        recognizer: SFSpeechRecognizer
    ) -> RecognitionHandle {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true

        let handle = RecognitionHandle(request: request)
        handle.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else {
                return
            }

            if let result {
                let merged = self.stateQueue.sync {
                    let offset = self.sourceOffsets[source] ?? 0
                    let mappedSegments = Self.mapLive(result: result, source: source, offset: offset)
                    self.sourceStates[source] = SourceTranscriptState(segments: mappedSegments)

                    let merged = Self.merge(sourceStates: self.sourceStates)
                    self.latestResult = merged
                    return merged
                }

                self.onUpdate?(merged)
            }

            if let error {
                self.onStatus?("\(source.permissionName.capitalized) capture stopped: \(error.localizedDescription)")
            }
        }

        return handle
    }

    private func startMicrophoneFeed(into request: SFSpeechAudioBufferRecognitionRequest) throws {
        let inputNode = audioEngine.inputNode
        try Self.route(inputNode: inputNode, toMicrophoneUID: preferredMicrophoneUID)
        let format = inputNode.inputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            throw SpeechRecorderError.audioEngineFailure
        }
    }

    private func startSpeakerFeed(into request: SFSpeechAudioBufferRecognitionRequest) async throws {
        stateQueue.sync {
            sourceOffsets[.speaker] = Date().timeIntervalSince(sessionStartedAt)
        }

        let capture = SystemAudioCapture(bundleIdentifier: Bundle.main.bundleIdentifier) { sampleBuffer in
            request.appendAudioSampleBuffer(sampleBuffer)
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

    private func endRecognitionRequests() {
        microphoneHandle?.request.endAudio()
        speakerHandle?.request.endAudio()
    }

    private func cancelRecognitionTasks() {
        microphoneHandle?.task?.cancel()
        speakerHandle?.task?.cancel()
        microphoneHandle = nil
        speakerHandle = nil
    }

    private func stopActiveCapture(statusMessage: String?) async {
        await stopInputFeeds()
        endRecognitionRequests()
        cancelRecognitionTasks()

        if let statusMessage {
            onStatus?(statusMessage)
        }
    }

    private static func merge(sourceStates: [TranscriptSource: SourceTranscriptState]) -> TranscriptionResult {
        let speakerOrder: [String: Int] = [
            TranscriptSource.microphone.speakerLabel: 0,
            TranscriptSource.speaker.speakerLabel: 1
        ]

        let mergedSegments = sourceStates
            .values
            .flatMap(\.segments)
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

    private static func mapLive(
        result: SFSpeechRecognitionResult,
        source: TranscriptSource,
        offset: TimeInterval
    ) -> [TranscriptSegment] {
        result.bestTranscription.segments.map { segment in
            TranscriptSegment(
                text: segment.substring,
                timestamp: segment.timestamp + offset,
                speaker: source.speakerLabel
            )
        }
    }

    private static func mapFile(result: SFSpeechRecognitionResult) -> TranscriptionResult {
        let segments = result.bestTranscription.segments.map { segment in
            TranscriptSegment(text: segment.substring, timestamp: segment.timestamp)
        }

        return TranscriptionResult(
            transcript: result.bestTranscription.formattedString,
            segments: segments
        )
    }

    private static func makeRecognizer(preferred: Locale) -> SFSpeechRecognizer? {
        let candidates = [
            preferred,
            Locale(identifier: "en_GB"),
            Locale(identifier: "en_US")
        ]

        for locale in candidates {
            if let recognizer = SFSpeechRecognizer(locale: locale) {
                return recognizer
            }
        }

        return nil
    }

    static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func requestScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        return CGRequestScreenCaptureAccess()
    }

    func availableMicrophones() -> [MicrophoneDevice] {
        Self.availableMicrophones()
    }

    static func availableMicrophones() -> [MicrophoneDevice] {
        let defaultUID = defaultInputDeviceUID()

        return allAudioDeviceIDs()
            .compactMap { deviceID in
                guard inputChannelCount(for: deviceID) > 0,
                      let uid = deviceUID(for: deviceID),
                      let name = deviceName(for: deviceID)
                else {
                    return nil
                }

                return MicrophoneDevice(
                    uid: uid,
                    name: name,
                    isSystemDefault: uid == defaultUID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isSystemDefault != rhs.isSystemDefault {
                    return lhs.isSystemDefault
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func defaultInputDeviceUID() -> String? {
        guard let deviceID = defaultInputDeviceID() else {
            return nil
        }

        return deviceUID(for: deviceID)
    }

    static func route(inputNode: AVAudioInputNode, toMicrophoneUID uid: String?) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw SpeechRecorderError.microphoneConfigurationFailure("Oatmeal could not access the input audio unit.")
        }

        guard let deviceID = uid.flatMap(translateDeviceUIDToDeviceID) ?? defaultInputDeviceID() else {
            throw SpeechRecorderError.microphoneConfigurationFailure("No input device is currently available.")
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        guard status == noErr else {
            throw SpeechRecorderError.microphoneConfigurationFailure("macOS returned OSStatus \(status).")
        }
    }

    private static func allAudioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = Array(repeating: AudioObjectID(0), count: count)
        guard AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs
    }

    private static func defaultInputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        return deviceID
    }

    private static func translateDeviceUIDToDeviceID(_ uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var cfUID = uid as CFString
        let qualifierSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutableBytes(of: &cfUID) { uidBuffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                uidBuffer.baseAddress,
                &dataSize,
                &deviceID
            )
        }

        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        return deviceID
    }

    private static func deviceUID(for deviceID: AudioObjectID) -> String? {
        stringProperty(
            selector: kAudioDevicePropertyDeviceUID,
            objectID: deviceID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private static func deviceName(for deviceID: AudioObjectID) -> String? {
        stringProperty(
            selector: kAudioObjectPropertyName,
            objectID: deviceID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private static func stringProperty(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr, let cfString = value?.takeUnretainedValue() else {
            return nil
        }

        return cfString as String
    }

    private static func inputChannelCount(for deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            rawPointer
        )

        guard status == noErr else {
            return 0
        }

        let bufferListPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return buffers.reduce(0) { partialResult, buffer in
            partialResult + Int(buffer.mNumberChannels)
        }
    }
}

final class SystemAudioCapture: NSObject {
    private let bundleIdentifier: String?
    private let onSampleBuffer: (CMSampleBuffer) -> Void
    private let onError: (Error) -> Void
    private let sampleHandlerQueue = DispatchQueue(label: "ai.codex.openola.system-audio")

    private var stream: SCStream?
    private var outputBridge: SystemAudioCaptureBridge?

    init(
        bundleIdentifier: String?,
        onSampleBuffer: @escaping (CMSampleBuffer) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.onSampleBuffer = onSampleBuffer
        self.onError = onError
    }

    func start() async throws {
        let shareableContent = try await SCShareableContent.current
        guard let display = shareableContent.displays.first else {
            throw SpeechRecorderError.noShareableDisplay
        }

        let includedApplications = shareableContent.applications.filter { application in
            let isCurrentProcess = application.processID == ProcessInfo.processInfo.processIdentifier
            let isCurrentBundle = application.bundleIdentifier == bundleIdentifier
            return !isCurrentProcess && !isCurrentBundle
        }

        let filter = SCContentFilter(
            display: display,
            including: includedApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true

        let bridge = SystemAudioCaptureBridge(onSampleBuffer: onSampleBuffer, onError: onError)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: bridge)
        try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: sampleHandlerQueue)
        try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        try await stream.startCapture()

        self.outputBridge = bridge
        self.stream = stream
    }

    func stop() async {
        guard let stream else {
            return
        }

        do {
            try await stream.stopCapture()
        } catch {
            onError(error)
        }

        self.stream = nil
        outputBridge = nil
    }
}

final class SystemAudioCaptureBridge: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onSampleBuffer: (CMSampleBuffer) -> Void
    private let onError: (Error) -> Void

    init(
        onSampleBuffer: @escaping (CMSampleBuffer) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onSampleBuffer = onSampleBuffer
        self.onError = onError
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        onSampleBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}
