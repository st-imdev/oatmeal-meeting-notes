import ArgumentParser
import Foundation


struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a meeting from the vault."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Meeting ID (or prefix) or title substring.")
    var query: String

    @Flag(name: [.short, .customLong("force")], help: "Skip confirmation prompt.")
    var force = false

    func run() async throws {
        let vault = MeetingVault(rootURL: vaultURL())
        let session = try await VaultResolver.resolve(query, in: vault)

        if !force {
            let shortID = String(session.id.uuidString.lowercased().prefix(8))
            print("Delete \(shortID) – \(session.title)?  [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                return
            }
        }

        try await vault.delete(session)
        print("Deleted \(session.title).")
    }

    private func vaultURL() -> URL {
        if let path = globals.vault {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return MeetingVault.defaultRootURL()
    }
}
