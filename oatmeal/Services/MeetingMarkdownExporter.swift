import Foundation

struct MeetingMarkdownExporter {
    func meetingMarkdown(for session: MeetingSession, userName: String = "") -> String {
        let transcript = session.resolvedCombinedTranscript(userName: userName).trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedTranscript = fallback(transcript, emptyMessage: "No transcript captured.")
        let participants = session.participantNames.isEmpty ? "None captured" : session.participantNames.joined(separator: ", ")

        return """
        ---
        id: "\(session.id.uuidString.lowercased())"
        title: "\(escaped(session.title))"
        status: "\(session.status.rawValue)"
        capture_mode: "\(session.captureMode.rawValue)"
        created_at: "\(session.createdAt.ISO8601Format())"
        updated_at: "\(session.updatedAt.ISO8601Format())"
        participants: [\(yamlInlineList(session.participantNames))]
        ---

        # \(session.title)

        Capture mode: `\(session.captureMode.rawValue)`
        Created: `\(session.createdAt.formatted(date: .abbreviated, time: .shortened))`
        Participants: \(participants)

        ## Transcript

        \(renderedTranscript)

        ## Files

        - Transcript: `transcript.md`
        - Metadata: `meta.json`
        - Segments: `transcript.json`
        """
    }

    func transcriptMarkdown(for session: MeetingSession, userName: String = "") -> String {
        let transcript = session.resolvedCombinedTranscript(userName: userName).trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedTranscript = fallback(transcript, emptyMessage: "No transcript captured.")

        return """
        ---
        id: "\(session.id.uuidString.lowercased())"
        title: "\(escaped(session.title))"
        created_at: "\(session.createdAt.ISO8601Format())"
        updated_at: "\(session.updatedAt.ISO8601Format())"
        ---

        # \(session.title) Transcript

        \(renderedTranscript)
        """
    }

    func markdown(for session: MeetingSession) -> String {
        meetingMarkdown(for: session)
    }

    func suggestedFilename(for session: MeetingSession) -> String {
        let sanitizedTitle = session.title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "--", with: "-")

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        return "\(sanitizedTitle)-\(formatter.string(from: session.createdAt)).md"
    }

    func writeMarkdown(for session: MeetingSession, to url: URL) throws {
        try meetingMarkdown(for: session).write(to: url, atomically: true, encoding: .utf8)
    }

    private func fallback(_ value: String, emptyMessage: String) -> String {
        value.isEmpty ? emptyMessage : value
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func yamlInlineList(_ items: [String]) -> String {
        items
            .map { "\"\(escaped($0))\"" }
            .joined(separator: ", ")
    }
}
