import ArgumentParser
import Foundation


struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio or video file."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Path to the audio/video file.")
    var file: String

    func run() async throws {
        let fileURL = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(fileURL.path)")
        }

        let vault = MeetingVault(rootURL: vaultURL())
        let recorder = FluidAudioRecorder()

        recorder.onDownloadProgress = { fraction, message in
            ProgressReporter.report(fraction: fraction, message: message)
        }

        recorder.onStatus = { message in
            FileHandle.standardError.write(Data("▸ \(message)\n".utf8))
        }

        FileHandle.standardError.write(Data("▸ Transcribing \(fileURL.lastPathComponent)…\n".utf8))
        let result = try await recorder.transcribeFile(at: fileURL)

        let session = MeetingSession(
            title: fileURL.deletingPathExtension().lastPathComponent,
            template: .general,
            captureMode: .importedRecording,
            status: .complete,
            transcript: result.transcript,
            transcriptSegments: result.segments
        )

        let saved = try await vault.save(session)
        let shortID = String(saved.id.uuidString.lowercased().prefix(8))

        for segment in result.segments {
            print(segment.renderedLine)
        }

        FileHandle.standardError.write(Data("\n▸ Saved \(shortID) – \(saved.title) (\(result.segments.count) segments)\n".utf8))
    }

    private func vaultURL() -> URL {
        if let path = globals.vault {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return MeetingVault.defaultRootURL()
    }
}
