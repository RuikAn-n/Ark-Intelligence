import Foundation

struct APIClient {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func stream(_ endpoint: APIEndpoint, body: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: endpoint.path))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200..<300).contains(httpResponse.statusCode) else {
                        throw APIError.invalidResponse
                    }

                    var eventName: String?
                    var data = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        } else if line.isEmpty, let parsedEventName = eventName, !data.isEmpty {
                            var event = try JSONDecoder().decode(ChatStreamEvent.self, from: Data(data.utf8))
                            if event.event != parsedEventName {
                                event = ChatStreamEvent(event: parsedEventName, requestID: event.requestID, model: event.model, stage: event.stage, content: event.content, error: event.error)
                            }
                            continuation.yield(event)
                            eventName = nil
                            data = ""
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "后端返回了无效响应。" }
}

struct ChatRequest: Encodable, Sendable {
    let message: String
}

@MainActor
final class LiveChatRepository: ChatRepository {
    private let client: APIClient
    init(baseURL: URL) { client = APIClient(baseURL: baseURL) }
    func streamMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        client.stream(.chatStream, body: ChatRequest(message: message))
    }
}
