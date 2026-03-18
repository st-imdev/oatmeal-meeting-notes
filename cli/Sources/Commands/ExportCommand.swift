import ArgumentParser
import Foundation


struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a meeting as Markdown to stdout."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Meeting ID (or prefix) or title substring.")
    var query: String

    func run() async throws {
        let vault = MeetingVault(rootURL: vaultURL())
        let session = try await VaultResolver.resolve(query, in: vault)
        let exporter = MeetingMarkdownExporter()
        print(exporter.meetingMarkdown(for: session))
    }

    private func vaultURL() -> URL {
        if let path = globals.vault {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return MeetingVault.defaultRootURL()
    }
}
