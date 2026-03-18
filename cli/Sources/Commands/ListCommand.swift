import ArgumentParser
import Foundation


struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all meetings in the vault."
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let vault = MeetingVault(rootURL: vaultURL())
        let sessions = try await vault.loadSessions()
        CLIFormatter.printMeetingTable(sessions)
    }

    private func vaultURL() -> URL {
        if let path = globals.vault {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return MeetingVault.defaultRootURL()
    }
}
