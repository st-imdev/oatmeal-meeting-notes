import Foundation


enum VaultResolver {
    /// Resolve a meeting by partial UUID prefix or case-insensitive title substring.
    static func resolve(_ query: String, in vault: MeetingVault) async throws -> MeetingSession {
        let sessions = try await vault.loadSessions()

        let lowered = query.lowercased()

        // Try exact UUID match first
        if let uuid = UUID(uuidString: query),
           let match = sessions.first(where: { $0.id == uuid }) {
            return match
        }

        // Try UUID prefix match
        let prefixMatches = sessions.filter {
            $0.id.uuidString.lowercased().hasPrefix(lowered)
        }
        if prefixMatches.count == 1 {
            return prefixMatches[0]
        }
        if prefixMatches.count > 1 {
            throw ResolverError.ambiguous(query, prefixMatches.map { $0.id.uuidString.lowercased().prefix(8) + " – " + $0.title })
        }

        // Try title substring match
        let titleMatches = sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
        if titleMatches.count == 1 {
            return titleMatches[0]
        }
        if titleMatches.count > 1 {
            throw ResolverError.ambiguous(query, titleMatches.map { $0.id.uuidString.lowercased().prefix(8) + " – " + $0.title })
        }

        throw ResolverError.notFound(query)
    }

    enum ResolverError: LocalizedError {
        case notFound(String)
        case ambiguous(String, [String])

        var errorDescription: String? {
            switch self {
            case .notFound(let query):
                return "No meeting matching \"\(query)\"."
            case .ambiguous(let query, let matches):
                let list = matches.map { "  \($0)" }.joined(separator: "\n")
                return "Multiple meetings match \"\(query)\":\n\(list)"
            }
        }
    }
}
