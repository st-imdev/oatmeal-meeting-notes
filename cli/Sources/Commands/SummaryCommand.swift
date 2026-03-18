import ArgumentParser
import Foundation


struct SummaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary",
        abstract: "Generate or show an LLM summary for a meeting."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Meeting ID (or prefix) or title substring.")
    var query: String

    func run() async throws {
        let vault = MeetingVault(rootURL: vaultURL())
        var session = try await VaultResolver.resolve(query, in: vault)

        // If notes already exist, just print them
        if let notes = session.generatedNotes {
            CLIFormatter.printNotes(notes)
            return
        }

        // Resolve API key: Keychain first, then env var
        let apiKey = KeychainHelper.load(key: "openRouterApiKey")
            ?? ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
            ?? ""

        let model = "anthropic/claude-sonnet-4"
        let engine = MeetingSummaryEngine()

        FileHandle.standardError.write(Data("▸ Generating summary…\n".utf8))
        let notes = await engine.generate(for: session, apiKey: apiKey, model: model)

        // Persist the generated notes
        session.generatedNotes = notes
        _ = try await vault.save(session)

        CLIFormatter.printNotes(notes)
    }

    private func vaultURL() -> URL {
        if let path = globals.vault {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return MeetingVault.defaultRootURL()
    }
}
