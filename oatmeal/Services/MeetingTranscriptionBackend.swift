import Foundation

protocol MeetingTranscriptionBackend: AnyObject {
    var onUpdate: ((TranscriptionResult) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    var preferredMicrophoneUID: String? { get set }

    func availableMicrophones() -> [MicrophoneDevice]
    func start() async throws
    func finish() async -> TranscriptionResult
    func transcribeFile(at url: URL) async throws -> TranscriptionResult
}
