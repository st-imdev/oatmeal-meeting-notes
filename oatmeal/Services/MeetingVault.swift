import Foundation

struct MeetingBundlePaths: Sendable {
    let directoryURL: URL
    let meetingMarkdownURL: URL
    let transcriptMarkdownURL: URL
    let metadataURL: URL
    let transcriptJSONURL: URL
}

actor MeetingVault {
    let rootURL: URL
    let meetingsDirectoryURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let markdownExporter: MeetingMarkdownExporter

    init(
        rootURL: URL = MeetingVault.defaultRootURL(),
        fileManager: FileManager = .default,
        markdownExporter: MeetingMarkdownExporter = MeetingMarkdownExporter()
    ) {
        self.rootURL = rootURL
        self.meetingsDirectoryURL = rootURL.appendingPathComponent("Meetings", isDirectory: true)
        self.fileManager = fileManager
        self.markdownExporter = markdownExporter

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadSessions() throws -> [MeetingSession] {
        try prepareDirectories()
        return sort(try readStoredSessions())
    }

    func loadSession(id: UUID) throws -> MeetingSession? {
        try readStoredSessions().first(where: { $0.id == id })
    }

    func save(_ session: MeetingSession, userName: String = "") throws -> MeetingSession {
        try prepareDirectories()

        var persisted = session
        if persisted.storageFolderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            persisted.storageFolderName = Self.makeDirectoryName(for: session)
        }

        let paths = bundlePaths(for: persisted)
        try fileManager.createDirectory(at: paths.directoryURL, withIntermediateDirectories: true)

        let metadata = try encoder.encode(persisted)
        try metadata.write(to: paths.metadataURL, options: .atomic)

        let transcriptJSON = try encoder.encode(persisted.transcriptSegments)
        try transcriptJSON.write(to: paths.transcriptJSONURL, options: .atomic)

        try markdownExporter.meetingMarkdown(for: persisted, userName: userName).write(
            to: paths.meetingMarkdownURL,
            atomically: true,
            encoding: .utf8
        )

        try markdownExporter.transcriptMarkdown(for: persisted, userName: userName).write(
            to: paths.transcriptMarkdownURL,
            atomically: true,
            encoding: .utf8
        )

        return persisted
    }

    func delete(_ session: MeetingSession) throws {
        let paths = bundlePaths(for: session)
        guard fileManager.fileExists(atPath: paths.directoryURL.path) else {
            return
        }

        try fileManager.removeItem(at: paths.directoryURL)
    }

    func bundlePaths(for session: MeetingSession) -> MeetingBundlePaths {
        let folderName = session.storageFolderName ?? Self.makeDirectoryName(for: session)
        return bundlePaths(forFolderName: folderName)
    }

    private func bundlePaths(forFolderName folderName: String) -> MeetingBundlePaths {
        let directoryURL = meetingsDirectoryURL.appendingPathComponent(folderName, isDirectory: true)
        return MeetingBundlePaths(
            directoryURL: directoryURL,
            meetingMarkdownURL: directoryURL.appendingPathComponent("meeting.md"),
            transcriptMarkdownURL: directoryURL.appendingPathComponent("transcript.md"),
            metadataURL: directoryURL.appendingPathComponent("meta.json"),
            transcriptJSONURL: directoryURL.appendingPathComponent("transcript.json")
        )
    }

    private func readStoredSessions() throws -> [MeetingSession] {
        guard fileManager.fileExists(atPath: meetingsDirectoryURL.path) else {
            return []
        }

        let candidates = try fileManager.contentsOfDirectory(
            at: meetingsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var sessions: [MeetingSession] = []

        for directoryURL in candidates {
            let resourceValues = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues.isDirectory == true else {
                continue
            }

            let metadataURL = directoryURL.appendingPathComponent("meta.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else {
                continue
            }

            let data = try Data(contentsOf: metadataURL)
            var session = try decoder.decode(MeetingSession.self, from: data)
            if session.storageFolderName == nil {
                session.storageFolderName = directoryURL.lastPathComponent
            }
            sessions.append(session)
        }

        return sort(sessions)
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: meetingsDirectoryURL, withIntermediateDirectories: true)
    }

    private func sort(_ sessions: [MeetingSession]) -> [MeetingSession] {
        sessions.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    static func defaultRootURL() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return documentsURL.appendingPathComponent("Oatmeal", isDirectory: true)
    }

    private static func makeDirectoryName(for session: MeetingSession) -> String {
        let timestamp = folderTimestampFormatter.string(from: session.createdAt)
        let title = slug(from: session.title)
        let shortID = session.id.uuidString.lowercased().prefix(8)
        return "\(timestamp)-\(title)-\(shortID)"
    }

    private static func slug(from value: String) -> String {
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        let pieces = normalized.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }

            return "-"
        }

        let collapsed = String(pieces)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return collapsed.isEmpty ? "meeting" : collapsed
    }

    private static let folderTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}
