import ArgumentParser
import Foundation


struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the local meeting API server."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Port to listen on (default: 48567).")
    var port: UInt16 = 48567

    func run() async throws {
        let vault = MeetingVault(rootURL: vaultURL())
        let server = MeetingAPIServer(vault: vault, port: port)
        let baseURL = try await server.start()
        print("Oatmeal API server running at \(baseURL.absoluteString)")
        print("Press Ctrl+C to stop.")

        // Block forever
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }

    private func vaultURL() -> URL {
        if let path = globals.vault {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return MeetingVault.defaultRootURL()
    }
}
