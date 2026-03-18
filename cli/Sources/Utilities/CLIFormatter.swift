import Foundation

enum CLIFormatter {
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    static func printMeetingTable(_ sessions: [MeetingSession]) {
        if sessions.isEmpty {
            print("No meetings found.")
            return
        }

        let header = col("ID", 10) + "  " + col("DATE", 20) + "  " + col("TITLE", 30) + "  " + col("SEGS", 6, right: true) + "  " + col("STATUS", 10)
        print(header)
        print(String(repeating: "─", count: 82))

        for session in sessions {
            let shortID = String(session.id.uuidString.lowercased().prefix(8))
            let date = formatDate(session.createdAt)
            let title = String(session.title.prefix(30))
            let segments = "\(session.transcriptSegments.count)"
            let status = session.status.label

            let row = col(shortID, 10) + "  " + col(date, 20) + "  " + col(title, 30) + "  " + col(segments, 6, right: true) + "  " + col(status, 10)
            print(row)
        }

        print("\n\(sessions.count) meeting\(sessions.count == 1 ? "" : "s")")
    }

    static func printTranscript(_ session: MeetingSession) {
        print("# \(session.title)")
        print("  \(formatDate(session.createdAt))  ·  \(session.status.label)")
        print()

        if session.transcriptSegments.isEmpty {
            let transcript = session.combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if transcript.isEmpty {
                print("(no transcript)")
            } else {
                print(transcript)
            }
        } else {
            for segment in session.transcriptSegments {
                print(segment.renderedLine)
            }
        }
    }

    static func printMicrophoneTable(_ mics: [MicrophoneDevice]) {
        if mics.isEmpty {
            print("No microphones found.")
            return
        }

        print(col("UID", 44) + "  " + "NAME")
        print(String(repeating: "─", count: 80))

        for mic in mics {
            print(col(mic.uid, 44) + "  " + mic.label)
        }
    }

    static func printNotes(_ notes: GeneratedMeetingNotes) {
        print("## \(notes.headline)")
        print()
        print(notes.summary)

        if !notes.keyTakeaways.isEmpty {
            print("\n### Key Takeaways")
            for item in notes.keyTakeaways {
                print("  - \(item)")
            }
        }

        if !notes.nextSteps.isEmpty {
            print("\n### Next Steps")
            for item in notes.nextSteps {
                print("  - \(item)")
            }
        }

        if !notes.questionsAndObjections.isEmpty {
            print("\n### Questions & Objections")
            for item in notes.questionsAndObjections {
                print("  - \(item)")
            }
        }

        if !notes.participants.isEmpty {
            print("\n### Participants")
            print("  \(notes.participants.joined(separator: ", "))")
        }
    }

    // MARK: - Private

    private static func col(_ text: String, _ width: Int, right: Bool = false) -> String {
        if text.count >= width {
            return String(text.prefix(width))
        }
        let padding = String(repeating: " ", count: width - text.count)
        return right ? padding + text : text + padding
    }
}
