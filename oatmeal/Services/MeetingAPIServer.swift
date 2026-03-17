import Foundation
import Network

private final class ListenerStartupState: @unchecked Sendable {
    var finished = false
}

struct MeetingAPIListItem: Codable, Sendable {
    let id: UUID
    let title: String
    let status: SessionStatus
    let captureMode: CaptureMode
    let createdAt: Date
    let updatedAt: Date
    let directoryURL: URL
    let meetingMarkdownURL: URL
    let transcriptMarkdownURL: URL
}

struct MeetingAPIDetail: Codable, Sendable {
    let session: MeetingSession
    let directoryURL: URL
    let meetingMarkdownURL: URL
    let transcriptMarkdownURL: URL
    let metadataURL: URL
    let transcriptJSONURL: URL
    let meetingMarkdown: String
    let transcriptMarkdown: String
}

final class MeetingAPIServer: @unchecked Sendable {
    private(set) var baseURL: URL

    private let vault: MeetingVault
    private let markdownExporter = MeetingMarkdownExporter()
    private let queue = DispatchQueue(label: "ai.codex.openola.api")
    private let encoder: JSONEncoder
    private let preferredPort: UInt16
    private var listener: NWListener?

    init(vault: MeetingVault, port: UInt16 = 48567) {
        self.vault = vault
        self.preferredPort = port
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func start() async throws -> URL {
        guard listener == nil else {
            return baseURL
        }

        let candidatePorts = [preferredPort, preferredPort + 1, preferredPort + 2, preferredPort + 3, 0]
        var lastError: Error?

        for candidatePort in candidatePorts {
            do {
                return try await startListener(on: candidatePort)
            } catch let error as NWError {
                lastError = error
                if case .posix(let code) = error, code == .EADDRINUSE {
                    continue
                }
                throw error
            } catch {
                lastError = error
                throw error
            }
        }

        throw lastError ?? URLError(.cannotCreateFile)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func startListener(on candidatePort: UInt16) async throws -> URL {
        let listener: NWListener
        if candidatePort == 0 {
            listener = try NWListener(using: .tcp)
        } else {
            guard let port = NWEndpoint.Port(rawValue: candidatePort) else {
                throw URLError(.badURL)
            }
            listener = try NWListener(using: .tcp, on: port)
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        let actualPort = try await awaitReady(listener)
        self.listener = listener
        self.baseURL = URL(string: "http://127.0.0.1:\(actualPort)")!
        return baseURL
    }

    private func awaitReady(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let startupState = ListenerStartupState()

            listener.stateUpdateHandler = { state in
                guard !startupState.finished else {
                    return
                }

                switch state {
                case .ready:
                    startupState.finished = true
                    continuation.resume(returning: listener.port?.rawValue ?? self.preferredPort)
                case .failed(let error):
                    startupState.finished = true
                    listener.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    startupState.finished = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            Task {
                let response = await self.response(for: data)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func response(for requestData: Data?) async -> Data {
        guard
            let requestData,
            let requestText = String(data: requestData, encoding: .utf8),
            let request = HTTPRequest(rawValue: requestText)
        else {
            return rawResponse(status: "400 Bad Request", body: "Bad Request")
        }

        do {
            switch request.method {
            case "GET" where request.pathComponents.isEmpty:
                return try jsonResponse([
                    "name": "Oatmeal Local API",
                    "openapi": "\(baseURL.absoluteString)/openapi.json",
                    "health": "\(baseURL.absoluteString)/health",
                    "meetings": "\(baseURL.absoluteString)/meetings",
                ])
            case "GET" where request.pathComponents == ["health"]:
                return try jsonResponse([
                    "status": "ok",
                    "base_url": baseURL.absoluteString,
                    "vault_root": vault.rootURL.path,
                ])
            case "GET" where request.pathComponents == ["openapi.json"]:
                return try jsonDataResponse(openAPIDocument())
            case "GET" where request.pathComponents == ["meetings"]:
                let sessions = try await vault.loadSessions()
                var payload: [MeetingAPIListItem] = []
                payload.reserveCapacity(sessions.count)

                for session in sessions {
                    payload.append(try await apiListItem(for: session))
                }

                return try jsonResponse(payload)
            case "GET" where request.pathComponents.count == 2 && request.pathComponents.first == "meetings":
                let idString = request.pathComponents[1]
                guard let sessionID = UUID(uuidString: idString) else {
                    return rawResponse(status: "400 Bad Request", body: "Invalid meeting id")
                }

                guard let detail = try await meetingDetail(for: sessionID) else {
                    return rawResponse(status: "404 Not Found", body: "Meeting not found")
                }

                return try jsonResponse(detail)
            default:
                return rawResponse(status: "404 Not Found", body: "Not Found")
            }
        } catch {
            return rawResponse(status: "500 Internal Server Error", body: error.localizedDescription)
        }
    }

    private func apiListItem(for session: MeetingSession) async throws -> MeetingAPIListItem {
        let paths = await vault.bundlePaths(for: session)
        return MeetingAPIListItem(
            id: session.id,
            title: session.title,
            status: session.status,
            captureMode: session.captureMode,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            directoryURL: paths.directoryURL,
            meetingMarkdownURL: paths.meetingMarkdownURL,
            transcriptMarkdownURL: paths.transcriptMarkdownURL
        )
    }

    private func meetingDetail(for sessionID: UUID) async throws -> MeetingAPIDetail? {
        guard let session = try await vault.loadSession(id: sessionID) else {
            return nil
        }

        let paths = await vault.bundlePaths(for: session)
        return MeetingAPIDetail(
            session: session,
            directoryURL: paths.directoryURL,
            meetingMarkdownURL: paths.meetingMarkdownURL,
            transcriptMarkdownURL: paths.transcriptMarkdownURL,
            metadataURL: paths.metadataURL,
            transcriptJSONURL: paths.transcriptJSONURL,
            meetingMarkdown: markdownExporter.meetingMarkdown(for: session),
            transcriptMarkdown: markdownExporter.transcriptMarkdown(for: session)
        )
    }

    private func jsonResponse<T: Encodable>(_ value: T) throws -> Data {
        let data = try encoder.encode(value)
        return httpResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: data)
    }

    private func jsonDataResponse(_ data: Data) throws -> Data {
        httpResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: data)
    }

    private func rawResponse(status: String, body: String) -> Data {
        httpResponse(
            status: status,
            contentType: "text/plain; charset=utf-8",
            body: Data(body.utf8)
        )
    }

    private func httpResponse(status: String, contentType: String, body: Data) -> Data {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private func openAPIDocument() -> Data {
        let document: [String: Any] = [
            "openapi": "3.1.0",
            "info": [
                "title": "Oatmeal Local API",
                "version": "0.1.0",
                "description": "Local read API for Markdown-backed meetings captured by the native macOS app.",
            ],
            "servers": [
                ["url": baseURL.absoluteString],
            ],
            "paths": [
                "/health": [
                    "get": [
                        "summary": "Health check",
                    ],
                ],
                "/meetings": [
                    "get": [
                        "summary": "List captured meetings",
                    ],
                ],
                "/meetings/{id}": [
                    "get": [
                        "summary": "Read a single meeting bundle",
                    ],
                ],
            ],
        ]

        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return data
    }
}

private struct HTTPRequest {
    let method: String
    let path: String

    var pathComponents: [String] {
        URL(string: "http://localhost\(path)")?
            .path
            .split(separator: "/")
            .map(String.init) ?? []
    }

    init?(rawValue: String) {
        guard let requestLine = rawValue.split(separator: "\r\n", maxSplits: 1).first else {
            return nil
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }

        self.method = String(parts[0]).uppercased()
        self.path = String(parts[1])
    }
}
