import Foundation

/// OpenAI-compatible client for the OpenRouter API.
/// Supports both streaming (SSE) and non-streaming completions.
actor OpenRouterClient {
    private let baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let max_tokens: Int?
    }

    /// Streams the completion response, yielding text chunks via SSE.
    func streamCompletion(
        apiKey: String,
        model: String,
        messages: [Message],
        maxTokens: Int = 1024
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = ChatRequest(
                        model: model,
                        messages: messages,
                        stream: true,
                        max_tokens: maxTokens
                    )

                    var urlRequest = URLRequest(url: baseURL)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("Oatmeal/1.0", forHTTPHeaderField: "HTTP-Referer")
                    urlRequest.httpBody = try JSONEncoder().encode(request)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        continuation.finish(throwing: OpenRouterError.httpError(statusCode))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8) else { continue }
                        if let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data),
                           let content = chunk.choices.first?.delta.content {
                            continuation.yield(content)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Non-streaming completion for structured JSON tasks.
    func complete(
        apiKey: String,
        model: String,
        messages: [Message],
        maxTokens: Int = 512
    ) async throws -> String {
        let request = ChatRequest(
            model: model,
            messages: messages,
            stream: false,
            max_tokens: maxTokens
        )

        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("Oatmeal/1.0", forHTTPHeaderField: "HTTP-Referer")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OpenRouterError.httpError(statusCode)
        }

        let completionResponse = try JSONDecoder().decode(CompletionResponse.self, from: data)
        return completionResponse.choices.first?.message.content ?? ""
    }

    enum OpenRouterError: Error, LocalizedError {
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .httpError(let code): "OpenRouter API error (HTTP \(code))"
            }
        }
    }

    // MARK: - SSE Types

    private struct SSEChunk: Codable {
        let choices: [Choice]

        struct Choice: Codable {
            let delta: Delta
        }

        struct Delta: Codable {
            let content: String?
        }
    }

    private struct CompletionResponse: Codable {
        let choices: [CompletionChoice]

        struct CompletionChoice: Codable {
            let message: CompletionMessage
        }

        struct CompletionMessage: Codable {
            let content: String
        }
    }
}
