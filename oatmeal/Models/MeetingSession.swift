import Foundation

enum CaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone
    case importedRecording

    var id: String { rawValue }

    var label: String {
        switch self {
        case .microphone:
            return "Live"
        case .importedRecording:
            return "Import"
        }
    }

    var detail: String {
        switch self {
        case .microphone:
            return "Live capture from your microphone plus speaker output."
        case .importedRecording:
            return "Transcript created from an audio or video file."
        }
    }
}

enum SessionStatus: String, Codable, Sendable {
    case draft
    case recording
    case transcribing
    case complete

    var label: String {
        switch self {
        case .draft:
            return "Draft"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .complete:
            return "Ready"
        }
    }
}

enum MeetingTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case general
    case customerDiscovery
    case oneOnOne
    case interview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general:
            return "Meeting"
        case .customerDiscovery:
            return "Customer Discovery"
        case .oneOnOne:
            return "1:1"
        case .interview:
            return "Interview"
        }
    }

    var icon: String {
        switch self {
        case .general:
            return "waveform"
        case .customerDiscovery:
            return "bubble.left.and.exclamationmark.bubble.right"
        case .oneOnOne:
            return "person.2.fill"
        case .interview:
            return "briefcase.fill"
        }
    }

    var defaultTitlePrefix: String {
        switch self {
        case .general:
            return "Meeting"
        case .customerDiscovery:
            return "Discovery Call"
        case .oneOnOne:
            return "1:1"
        case .interview:
            return "Interview"
        }
    }

    var notePrompt: String {
        switch self {
        case .general:
            return ""
        case .customerDiscovery:
            return """
            Capture:
            - Goals they mentioned
            - Pain points and workarounds
            - Budget, urgency, ownership
            - Objections or missing pieces
            """
        case .oneOnOne:
            return """
            Capture:
            - Wins and blockers
            - Decisions that got made
            - Coaching notes
            - Follow-ups before next week
            """
        case .interview:
            return """
            Capture:
            - Strong signals
            - Gaps or risks
            - Evidence from examples
            - Recommendation and next step
            """
        }
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var timestamp: TimeInterval?
    var speaker: String?

    var renderedLine: String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let speaker, !speaker.isEmpty else {
            return trimmedText
        }

        return "\(speaker): \(trimmedText)"
    }
}

struct PromptAnswer: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var prompt: String
    var answer: String
}

struct GeneratedMeetingNotes: Codable, Hashable, Sendable {
    var headline: String
    var summary: String
    var keyTakeaways: [String]
    var nextSteps: [String]
    var questionsAndObjections: [String]
    var participants: [String]
    var promptAnswers: [PromptAnswer]
    var generatedAt: Date
}

struct MeetingSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var template: MeetingTemplate
    var captureMode: CaptureMode
    var status: SessionStatus
    var participants: String
    var manualNotes: String
    var transcript: String
    var transcriptSegments: [TranscriptSegment]
    var generatedNotes: GeneratedMeetingNotes?
    var storageFolderName: String?
    var speakerNameMap: [String: String]?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        template: MeetingTemplate,
        captureMode: CaptureMode = .microphone,
        status: SessionStatus = .draft,
        participants: String = "",
        manualNotes: String = "",
        transcript: String = "",
        transcriptSegments: [TranscriptSegment] = [],
        generatedNotes: GeneratedMeetingNotes? = nil,
        storageFolderName: String? = nil,
        speakerNameMap: [String: String]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.template = template
        self.captureMode = captureMode
        self.status = status
        self.participants = participants
        self.manualNotes = manualNotes
        self.transcript = transcript
        self.transcriptSegments = transcriptSegments
        self.generatedNotes = generatedNotes
        self.storageFolderName = storageFolderName
        self.speakerNameMap = speakerNameMap
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func draft(template: MeetingTemplate = .general, title: String? = nil) -> MeetingSession {
        let stamp = DateFormatter.sessionTitle.string(from: Date())
        let sessionTitle = title ?? "Meeting \(stamp)"
        return MeetingSession(
            title: sessionTitle,
            template: template
        )
    }

    var participantNames: [String] {
        participants
            .split(separator: ",")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var combinedTranscript: String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranscript.isEmpty {
            return trimmedTranscript
        }

        return transcriptSegments
            .map(\.renderedLine)
            .joined(separator: "\n")
    }

    func resolvedSpeakerName(for rawSpeaker: String, userName: String) -> String {
        if rawSpeaker == "Me", !userName.isEmpty {
            return userName
        }
        if let mapped = speakerNameMap?[rawSpeaker], !mapped.isEmpty {
            return mapped
        }
        return rawSpeaker
    }

    func resolvedCombinedTranscript(userName: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranscript.isEmpty {
            return trimmedTranscript
        }

        return transcriptSegments.map { segment in
            let trimmedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let speaker = segment.speaker, !speaker.isEmpty else {
                return trimmedText
            }
            let resolved = resolvedSpeakerName(for: speaker, userName: userName)
            return "\(resolved): \(trimmedText)"
        }.joined(separator: "\n")
    }

    var noteLines: [String] {
        manualNotes
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension DateFormatter {
    static let sessionTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    static let shortMeta: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    @MainActor
    static let sidebarMeta: RelativeDateTimeFormatter = {
        RelativeDateTimeFormatter()
    }()
}
