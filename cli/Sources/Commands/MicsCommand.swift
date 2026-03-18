import ArgumentParser


struct MicsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mics",
        abstract: "List available microphones."
    )

    func run() async throws {
        let mics = SpeechRecorder.availableMicrophones()
        CLIFormatter.printMicrophoneTable(mics)
    }
}
