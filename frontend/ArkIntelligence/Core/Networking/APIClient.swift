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
                    request.timeoutInterval = 900
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
                    func emitPendingEvent() throws {
                        guard let eventName, !data.isEmpty else { return }
                        var event = try JSONDecoder().decode(ChatStreamEvent.self, from: Data(data.utf8))
                        if event.event != eventName {
                            event = ChatStreamEvent(event: eventName, requestID: event.requestID, model: event.model, stage: event.stage, content: event.content, error: event.error, items: event.items)
                        }
                        continuation.yield(event)
                    }
                    for try await line in bytes.lines {
                        let normalizedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if normalizedLine.hasPrefix("event:") {
                            try emitPendingEvent()
                            eventName = normalizedLine.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            data = ""
                        } else if normalizedLine.hasPrefix("data:") {
                            data = String(normalizedLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        } else if normalizedLine.isEmpty {
                            try emitPendingEvent()
                            eventName = nil
                            data = ""
                        }
                    }
                    try emitPendingEvent()
                    continuation.finish()
                } catch {
                    print("[APIClient] SSE error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func request<T: Decodable>(_ endpoint: APIEndpoint, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: endpoint.path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum APIError: LocalizedError {
    case invalidURL, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidURL: "后端地址无效。"
        case .invalidResponse: "后端返回了无效响应。"
        }
    }
}

struct ChatRequest: Encodable, Sendable {
    let message: String
}

struct MemoryPayload: Encodable {
    let content: String
    let category: String
    let memoryType: String
    let source: String
    let confidence: Double
    let importance: Double

    enum CodingKeys: String, CodingKey {
        case content, category, source, confidence, importance
        case memoryType = "memory_type"
    }
}

struct MemoryListResponse: Decodable { let memories: [MemoryDTO] }

struct MemoryDTO: Decodable {
    let id: Int
    let content: String
    let category: String
    let memoryType: String
    let source: String
    let createdAt: String
    let updatedAt: String?
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, content, category, source, status
        case memoryType = "memory_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    func domain() -> MemoryItem {
        let formatter = ISO8601DateFormatter()
        func parse(_ value: String) -> Date {
            if let date = formatter.date(from: value) { return date }
            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            fallback.timeZone = TimeZone(secondsFromGMT: 0)
            fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            return fallback.date(from: value) ?? .now
        }
        let created = parse(createdAt)
        let normalizedCategory = MemoryCategory(rawValue: category.capitalized) ?? .general
        return MemoryItem(id: id, content: content, category: normalizedCategory, source: MemorySource(rawValue: source) ?? .inferred, createdAt: created, updatedAt: parse(updatedAt ?? createdAt), isDeleted: status == "deleted")
    }
}

@MainActor
final class LiveChatRepository: ChatRepository {
    private let client: APIClient
    init(baseURL: URL) { client = APIClient(baseURL: baseURL) }
    func streamMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        client.stream(.chatStream, body: ChatRequest(message: message))
    }

    func endSession() async throws -> SessionEndResponse {
        try await client.request(.sessionEnd, method: "POST")
    }
}

@MainActor
final class LiveMemoryRepository: MemoryRepository {
    private let client: APIClient
    init(baseURL: URL) { client = APIClient(baseURL: baseURL) }

    func fetchMemories() async throws -> [MemoryItem] {
        let response: MemoryListResponse = try await client.request(.memories, query: [URLQueryItem(name: "include_deleted", value: "true")])
        return response.memories.map { $0.domain() }
    }

    func createMemory(_ memory: MemoryItem) async throws -> MemoryItem {
        let payload = MemoryPayload(content: memory.content, category: memory.category.rawValue, memoryType: "fact", source: memory.source.rawValue, confidence: 1, importance: 0.5)
        let data = try JSONEncoder().encode(payload)
        let response: MemoryDTO = try await client.request(.memories, method: "POST", body: data)
        return response.domain()
    }

    func updateMemory(_ memory: MemoryItem) async throws {
        let payload = MemoryPayload(content: memory.content, category: memory.category.rawValue, memoryType: "fact", source: memory.source.rawValue, confidence: 1, importance: 0.5)
        let data = try JSONEncoder().encode(payload)
        let _: MemoryDTO = try await client.request(.memory(id: memory.id), method: "PATCH", body: data)
    }

    func softDeleteMemory(_ memory: MemoryItem) async throws {
        let _: MemoryDeleteResponse = try await client.request(.memory(id: memory.id), method: "DELETE")
    }

    func permanentlyDeleteMemory(_ memory: MemoryItem) async throws {
        let _: MemoryDeleteResponse = try await client.request(.memory(id: memory.id), method: "DELETE", query: [URLQueryItem(name: "permanent", value: "true")])
    }
}

private struct MemoryDeleteResponse: Decodable {
    let status: String
    let permanent: Bool
}
