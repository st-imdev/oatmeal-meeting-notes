import ArgumentParser
import Foundation


struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print a meeting transcript."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Meeting ID (or prefix) or title substring.")
    var query: String

    func run() async throws {
        let vault = MeetingVault(rootURL: vaultURL())
        let session = try await VaultResolver.resolve(query, in: vault)
        CLIFormatter.printTranscript(session)
    }

    private func vaultURL() -> URL {
        if let path = globals.vault {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return MeetingVault.defaultRootURL()
    }
}
