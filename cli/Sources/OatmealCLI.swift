import ArgumentParser

@main
struct OatmealCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oatmeal",
        abstract: "Meeting transcription from the command line.",
        subcommands: [
            ListCommand.self,
            ShowCommand.self,
            RecordCommand.self,
            TranscribeCommand.self,
            ExportCommand.self,
            DeleteCommand.self,
            MicsCommand.self,
            ServeCommand.self,
            SummaryCommand.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the Oatmeal vault directory.")
    var vault: String?
}
