import Foundation

struct MeetingSummaryEngine {
    private let client = OpenRouterClient()

    /// Generate meeting notes using OpenRouter LLM if an API key is available,
    /// otherwise fall back to the local keyword-based heuristic.
    func generate(for session: MeetingSession, apiKey: String, model: String) async -> GeneratedMeetingNotes {
        let transcript = session.combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Need a meaningful transcript and a configured API key
        if !apiKey.isEmpty && transcript.count > 60 {
            if let llmNotes = await generateWithLLM(session: session, transcript: transcript, apiKey: apiKey, model: model) {
                return llmNotes
            }
        }

        // Fallback: local heuristic
        return generateLocal(for: session)
    }

    /// Legacy synchronous entry point (local only).
    func generate(for session: MeetingSession) -> GeneratedMeetingNotes {
        generateLocal(for: session)
    }

    // MARK: - LLM Summary

    private func generateWithLLM(session: MeetingSession, transcript: String, apiKey: String, model: String) async -> GeneratedMeetingNotes? {
        let systemPrompt = """
        You are a meeting notes assistant. Given a transcript, produce structured meeting notes as JSON. \
        Keep everything concise and actionable.

        Output only valid JSON matching this schema:
        {
          "headline": "string (≤15 words summarizing the meeting)",
          "summary": "string (2-4 sentences)",
          "keyTakeaways": ["string", ...],
          "nextSteps": ["string", ...],
          "questionsAndObjections": ["string", ...],
          "participants": ["string", ...]
        }

        Rules:
        - "Me" in the transcript is the user; "Them" is the other party.
        - If participants aren't named, use "Me" and "Them".
        - Keep arrays to 3-5 items max.
        - Be concrete — avoid generic filler.
        """

        // Truncate very long transcripts to stay within context
        let maxChars = 12_000
        let truncatedTranscript = transcript.count > maxChars
            ? String(transcript.prefix(maxChars)) + "\n[…transcript truncated]"
            : transcript

        let userPrompt = """
        Meeting: \(session.title)
        Date: \(session.createdAt.formatted(date: .abbreviated, time: .shortened))

        Transcript:
        \(truncatedTranscript)

        Generate the meeting notes as JSON:
        """

        let messages: [OpenRouterClient.Message] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: userPrompt)
        ]

        do {
            let response = try await client.complete(
                apiKey: apiKey,
                model: model,
                messages: messages,
                maxTokens: 1024
            )

            let jsonString = extractJSON(from: response)
            guard let data = jsonString.data(using: .utf8) else { return nil }

            let decoded = try JSONDecoder().decode(LLMSummaryOutput.self, from: data)
            return GeneratedMeetingNotes(
                headline: decoded.headline,
                summary: decoded.summary,
                keyTakeaways: decoded.keyTakeaways,
                nextSteps: decoded.nextSteps,
                questionsAndObjections: decoded.questionsAndObjections,
                participants: decoded.participants,
                promptAnswers: [
                    PromptAnswer(prompt: "What did they say?", answer: decoded.summary),
                    PromptAnswer(
                        prompt: "List action items.",
                        answer: decoded.nextSteps.isEmpty
                            ? "No explicit action items captured."
                            : decoded.nextSteps.map { "- \($0)" }.joined(separator: "\n")
                    ),
                    PromptAnswer(
                        prompt: "What questions did they have?",
                        answer: decoded.questionsAndObjections.isEmpty
                            ? "No explicit questions captured."
                            : decoded.questionsAndObjections.map { "- \($0)" }.joined(separator: "\n")
                    ),
                ],
                generatedAt: Date()
            )
        } catch {
            // LLM failed — caller will fall back to local
            return nil
        }
    }

    private struct LLMSummaryOutput: Codable {
        let headline: String
        let summary: String
        let keyTakeaways: [String]
        let nextSteps: [String]
        let questionsAndObjections: [String]
        let participants: [String]
    }

    private func extractJSON(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") {
            s = String(s.dropFirst(7))
        } else if s.hasPrefix("```") {
            s = String(s.dropFirst(3))
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Local Heuristic Fallback

    func generateLocal(for session: MeetingSession) -> GeneratedMeetingNotes {
        let transcript = session.combinedTranscript
        let transcriptLines = normalize(lines: transcriptLines(from: transcript, fallbackSegments: session.transcriptSegments))
        let summarySentences = buildSummarySentences(transcriptLines: transcriptLines)
        let takeaways = buildKeyTakeaways(transcriptLines: transcriptLines)
        let nextSteps = buildNextSteps(transcriptLines: transcriptLines)
        let questions = buildQuestions(transcriptLines: transcriptLines)
        let participants = buildParticipants(session: session, transcriptLines: transcriptLines)

        return GeneratedMeetingNotes(
            headline: buildHeadline(session: session, transcriptLines: transcriptLines),
            summary: summarySentences.joined(separator: " "),
            keyTakeaways: takeaways,
            nextSteps: nextSteps,
            questionsAndObjections: questions,
            participants: participants,
            promptAnswers: [
                PromptAnswer(
                    prompt: "What did they say?",
                    answer: summarySentences.isEmpty ? "No transcript highlights yet." : summarySentences.joined(separator: " ")
                ),
                PromptAnswer(
                    prompt: "List action items.",
                    answer: nextSteps.isEmpty ? "No explicit action items captured." : nextSteps.map { "- \($0)" }.joined(separator: "\n")
                ),
                PromptAnswer(
                    prompt: "What questions did they have?",
                    answer: questions.isEmpty ? "No explicit questions captured." : questions.map { "- \($0)" }.joined(separator: "\n")
                ),
            ],
            generatedAt: Date()
        )
    }

    private func buildHeadline(session: MeetingSession, transcriptLines: [String]) -> String {
        if let leadTranscript = transcriptLines.first(where: isHeadlineCandidate) {
            return leadTranscript
        }
        let formattedDate = session.createdAt.formatted(date: .abbreviated, time: .omitted)
        return "Meeting on \(formattedDate)"
    }

    private func buildSummarySentences(transcriptLines: [String]) -> [String] {
        let transcriptCandidates = Array(transcriptLines
            .flatMap(splitIntoSentences)
            .filter { $0.count > 32 }
            .filter { !$0.hasPrefix("-") }
            .prefix(3))
        return Array(normalize(lines: transcriptCandidates).prefix(3))
    }

    private func buildKeyTakeaways(transcriptLines: [String]) -> [String] {
        let transcriptMatches = score(lines: transcriptLines, keywords: [
            "goal", "priority", "important", "decided", "plan", "need", "challenge", "opportunity",
        ])
        return Array(fallback(
            normalize(lines: Array(transcriptMatches)),
            fallback: normalize(lines: Array(transcriptLines.prefix(4)))
        ).prefix(4))
    }

    private func buildNextSteps(transcriptLines: [String]) -> [String] {
        let actionKeywords = [
            "follow up", "send", "share", "intro", "introduce", "schedule", "review", "decide",
            "next step", "action", "todo", "owner", "ship", "draft", "prepare",
        ]
        let prefixedActions = transcriptLines.filter { line in
            let lowercased = line.lowercased()
            return lowercased.hasPrefix("todo")
                || lowercased.hasPrefix("next")
                || lowercased.hasPrefix("action")
                || lowercased.hasPrefix("- [")
                || actionKeywords.contains(where: lowercased.contains)
        }
        return Array(fallback(
            normalize(lines: prefixedActions),
            fallback: normalize(lines: score(lines: transcriptLines, keywords: actionKeywords))
        ).prefix(5))
    }

    private func buildQuestions(transcriptLines: [String]) -> [String] {
        let concernKeywords = [
            "?", "concern", "risk", "blocked", "objection", "worried", "unclear", "question",
        ]
        let matches = transcriptLines.filter { line in
            let lowercased = line.lowercased()
            return line.contains("?") || concernKeywords.contains(where: lowercased.contains)
        }
        return Array(fallback(
            normalize(lines: matches),
            fallback: normalize(lines: score(lines: transcriptLines, keywords: concernKeywords))
        ).prefix(4))
    }

    private func buildParticipants(session: MeetingSession, transcriptLines: [String]) -> [String] {
        let manualParticipants = normalize(lines: session.participantNames)
        if !manualParticipants.isEmpty {
            return manualParticipants
        }
        let inferred = transcriptLines.compactMap { line -> String? in
            guard let colonIndex = line.firstIndex(of: ":") else { return nil }
            let possibleName = String(line[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard possibleName.count >= 2, possibleName.count <= 30 else { return nil }
            let tokens = possibleName.split(separator: " ")
            guard !tokens.isEmpty, tokens.count <= 3 else { return nil }
            return possibleName
        }
        return Array(normalize(lines: inferred).prefix(6))
    }

    private func transcriptLines(from transcript: String, fallbackSegments: [TranscriptSegment]) -> [String] {
        let directLines = transcript
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !directLines.isEmpty {
            return directLines
        }
        return fallbackSegments.map(\.renderedLine)
    }

    private func splitIntoSentences(_ line: String) -> [String] {
        line
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { sentence in
                sentence.hasSuffix(".") ? sentence : "\(sentence)."
            }
    }

    private func score(lines: [String], keywords: [String]) -> [String] {
        lines
            .map { line in
                let score = keywords.reduce(into: 0) { partialResult, keyword in
                    if line.localizedCaseInsensitiveContains(keyword) {
                        partialResult += 1
                    }
                }
                return (line, score)
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.count > rhs.0.count
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
    }

    private func normalize(lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.compactMap { line in
            let compact = line
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "•", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !compact.isEmpty else { return nil }
            let canonical = compact.lowercased()
            guard !seen.contains(canonical) else { return nil }
            seen.insert(canonical)
            return compact
        }
    }

    private func fallback(_ lines: [String], fallback: [String]) -> [String] {
        lines.isEmpty ? fallback : lines
    }

    private func isHeadlineCandidate(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return line.count >= 18
            && !lowercased.hasPrefix("todo")
            && !lowercased.hasPrefix("next")
            && !lowercased.hasPrefix("action")
    }
}
