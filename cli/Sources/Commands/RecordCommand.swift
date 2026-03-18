import ArgumentParser
import Dispatch
import Foundation


struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record a live meeting from the microphone."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Microphone UID to use (see `oatmeal mics`).")
    var mic: String?

    func run() async throws {
        let vault = MeetingVault(rootURL: vaultURL())
        let recorder = FluidAudioRecorder()

        if let mic {
            recorder.preferredMicrophoneUID = mic
        }

        recorder.onDownloadProgress = { fraction, message in
            ProgressReporter.report(fraction: fraction, message: message)
        }

        recorder.onStatus = { message in
            FileHandle.standardError.write(Data("▸ \(message)\n".utf8))
        }

        var segmentCount = 0
        recorder.onUpdate = { result in
            // Print only newly added segments
            let newSegments = result.segments.dropFirst(segmentCount)
            for segment in newSegments {
                print(segment.renderedLine)
                fflush(stdout)
            }
            segmentCount = result.segments.count
        }

        // Trap SIGINT so Ctrl+C finalizes cleanly instead of killing the process
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)

        let finished = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        finished.initialize(to: false)
        defer { finished.deallocate() }

        sigintSource.setEventHandler {
            if !finished.pointee {
                finished.pointee = true
                FileHandle.standardError.write(Data("\n▸ Stopping…\n".utf8))
            }
        }
        sigintSource.resume()

        // Start recording
        try await recorder.start()
        FileHandle.standardError.write(Data("▸ Recording. Press Ctrl+C to stop.\n".utf8))

        // Poll until SIGINT is received
        while !finished.pointee {
            try await Task.sleep(for: .milliseconds(200))
        }

        // Finalize
        let result = await recorder.finish()

        var session = MeetingSession.draft()
        session.status = .complete
        session.transcript = result.transcript
        session.transcriptSegments = result.segments

        let saved = try await vault.save(session)
        let shortID = String(saved.id.uuidString.lowercased().prefix(8))

        FileHandle.standardError.write(Data("▸ Saved \(shortID) – \(saved.title) (\(result.segments.count) segments)\n".utf8))

        sigintSource.cancel()
    }

    private func vaultURL() -> URL {
        if let path = globals.vault {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return MeetingVault.defaultRootURL()
    }
}
