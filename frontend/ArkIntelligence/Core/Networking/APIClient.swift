import Foundation

struct APIClient: Sendable {
    let baseURL: URL

    private var token: String {
        get throws {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let url = base.appendingPathComponent("ArkIntelligence/runtime/token")
            guard let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 32 else {
                throw APIError.authenticationUnavailable
            }
            return value
        }
    }

    func url(for endpoint: APIEndpoint, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(url: baseURL.appending(path: endpoint.path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw APIError.invalidURL }
        return url
    }

    func authorizedRequest(_ endpoint: APIEndpoint, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url(for: endpoint, query: query))
        request.httpMethod = method
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    func streamRun(_ runID: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lastEventID = 0, attempts = 0
                var terminal = false
                while !terminal && !Task.isCancelled {
                    do {
                        var request = try authorizedRequest(.runEvents(id: runID), query: [URLQueryItem(name: "after", value: String(lastEventID))])
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw APIError.invalidResponse }
                        var eventName: String?
                        var dataLines: [String] = []
                        func emit() throws {
                            guard let eventName, !dataLines.isEmpty else { return }
                            var event = try JSONDecoder().decode(ChatStreamEvent.self, from: Data(dataLines.joined(separator: "\n").utf8))
                            if event.event != eventName {
                                event = ChatStreamEvent(event: eventName, requestID: event.requestID, runID: event.runID, eventID: event.eventID, model: event.model, stage: event.stage, content: event.content, error: event.error, items: event.items, callID: event.callID, actionID: event.actionID, digest: event.digest, preview: event.preview)
                            }
                            if let id = event.eventID { lastEventID = max(lastEventID, id) }
                            if event.event == "done" || event.event == "error" { terminal = true }
                            continuation.yield(event)
                        }
                        for try await line in bytes.lines {
                            if line.hasPrefix("event:") {
                                try emit(); eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces); dataLines = []
                            } else if line.hasPrefix("data:") {
                                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                            } else if line.isEmpty {
                                try emit(); eventName = nil; dataLines = []
                            }
                        }
                        try emit()
                        if !terminal { throw APIError.invalidResponse }
                    } catch is CancellationError {
                        continuation.finish(); return
                    } catch {
                        attempts += 1
                        if attempts >= 5 { continuation.finish(throwing: error); return }
                        try? await Task.sleep(for: .seconds(min(attempts, 3)))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func request<T: Decodable>(_ endpoint: APIEndpoint, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        let request = try authorizedRequest(endpoint, method: method, query: query, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(APIErrorResponse.self, from: data).detail) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIError.server(detail)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct APIErrorResponse: Decodable { let detail: String }

enum APIError: LocalizedError {
    case invalidURL, invalidResponse, authenticationUnavailable, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "后端地址无效。"
        case .invalidResponse: "后端返回了无效响应。"
        case .authenticationUnavailable: "找不到本地认证信息。请先启动 Ark 后端。"
        case .server(let detail): detail
        }
    }
}

struct ChatRequest: Encodable, Sendable { let message: String }
private struct RunRequest: Encodable, Sendable {
    let inputMode: String
    let sessionID: String; let message: String; let currentTime: String; let timezone: String; let history: [HistoryPayload]
    enum CodingKeys: String, CodingKey { case message, timezone, history; case inputMode = "input_mode"; case sessionID = "session_id"; case currentTime = "current_time" }
}
private struct HistoryPayload: Encodable, Sendable { let role: String; let content: String }
private struct RunCreated: Decodable { let id: String }
private struct ApprovalPayload: Encodable {
    let callID: String; let digest: String; let approved: Bool
    enum CodingKeys: String, CodingKey { case digest, approved; case callID = "call_id" }
}
private struct SessionPayload: Encodable {
    let sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}
private struct StatusResponse: Decodable { let status: String }

@MainActor
final class LiveChatRepository: ChatRepository {
    private let client: APIClient
    private var sessionID = UUID().uuidString
    private var restoredHistory: [HistoryPayload] = []
    init(baseURL: URL) { client = APIClient(baseURL: baseURL) }

    func streamMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        stream(message, inputMode: "text")
    }

    func streamVoiceMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        stream(message, inputMode: "voice")
    }

    private func stream(_ message: String, inputMode: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let history = restoredHistory
        let currentSessionID = sessionID
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let payload = RunRequest(inputMode: inputMode, sessionID: currentSessionID, message: message, currentTime: Date().ISO8601Format(), timezone: TimeZone.current.identifier, history: history)
                    let run: RunCreated = try await client.request(.runs, method: "POST", body: JSONEncoder().encode(payload))
                    if sessionID == currentSessionID { restoredHistory = [] }
                    for try await event in client.streamRun(run.id) { continuation.yield(event) }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func submitApproval(runID: String, callID: String, digest: String, approved: Bool) async throws {
        let data = try JSONEncoder().encode(ApprovalPayload(callID: callID, digest: digest, approved: approved))
        let _: StatusResponse = try await client.request(.runApproval(id: runID), method: "POST", body: data)
    }
    func cancel(runID: String) async throws { let _: StatusResponse = try await client.request(.runCancel(id: runID), method: "POST") }
    func restoreHistory(_ messages: [ChatMessage]) {
        sessionID = UUID().uuidString
        restoredHistory = messages.filter { $0.role == .user || $0.role == .assistant }.suffix(12).map { HistoryPayload(role: $0.role.rawValue, content: String($0.content.prefix(4000))) }
    }
    func endSession() async throws -> SessionEndResponse {
        let data = try JSONEncoder().encode(SessionPayload(sessionID: sessionID))
        return try await client.request(.sessionsEnd, method: "POST", body: data)
    }
}

struct MemoryPayload: Encodable {
    let content: String; let category: String; let memoryType: String; let source: String; let confidence: Double; let importance: Double
    enum CodingKeys: String, CodingKey { case content, category, source, confidence, importance; case memoryType = "memory_type" }
}
struct MemoryListResponse: Decodable { let memories: [MemoryDTO] }
struct MemoryDTO: Decodable {
    let id: Int; let content: String; let category: String; let memoryType: String; let source: String; let createdAt: String; let updatedAt: String?; let status: String
    enum CodingKeys: String, CodingKey { case id, content, category, source, status; case memoryType = "memory_type"; case createdAt = "created_at"; case updatedAt = "updated_at" }
    func domain() -> MemoryItem {
        let formatter = ISO8601DateFormatter()
        func parse(_ value: String) -> Date {
            if let date = formatter.date(from: value) { return date }
            let fallback = DateFormatter(); fallback.locale = Locale(identifier: "en_US_POSIX"); fallback.timeZone = TimeZone(secondsFromGMT: 0); fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            return fallback.date(from: value) ?? .now
        }
        let created = parse(createdAt)
        return MemoryItem(id: id, content: content, category: MemoryCategory(rawValue: category.capitalized) ?? .general, source: MemorySource(rawValue: source) ?? .inferred, createdAt: created, updatedAt: parse(updatedAt ?? createdAt), isDeleted: status == "deleted")
    }
}

@MainActor
final class LiveMemoryRepository: MemoryRepository {
    private let client: APIClient
    init(baseURL: URL) { client = APIClient(baseURL: baseURL) }
    func fetchMemories() async throws -> [MemoryItem] { let response: MemoryListResponse = try await client.request(.memories, query: [URLQueryItem(name: "include_deleted", value: "true")]); return response.memories.map { $0.domain() } }
    func createMemory(_ memory: MemoryItem) async throws -> MemoryItem {
        let payload = MemoryPayload(content: memory.content, category: memory.category.rawValue, memoryType: "fact", source: memory.source.rawValue, confidence: 1, importance: 0.5)
        let response: MemoryDTO = try await client.request(.memories, method: "POST", body: JSONEncoder().encode(payload)); return response.domain()
    }
    func updateMemory(_ memory: MemoryItem) async throws {
        let payload = MemoryPayload(content: memory.content, category: memory.category.rawValue, memoryType: "fact", source: memory.source.rawValue, confidence: 1, importance: 0.5)
        let _: MemoryDTO = try await client.request(.memory(id: memory.id), method: "PATCH", body: JSONEncoder().encode(payload))
    }
    func softDeleteMemory(_ memory: MemoryItem) async throws { let _: MemoryDeleteResponse = try await client.request(.memory(id: memory.id), method: "DELETE") }
    func permanentlyDeleteMemory(_ memory: MemoryItem) async throws { let _: MemoryDeleteResponse = try await client.request(.memory(id: memory.id), method: "DELETE", query: [URLQueryItem(name: "permanent", value: "true")]) }
}
private struct MemoryDeleteResponse: Decodable { let status: String; let permanent: Bool }
private struct SkillListResponse: Decodable { let skills: [Skill] }
private struct SkillToggle: Encodable { let enabled: Bool }

@MainActor
final class LiveSkillRepository: SkillRepository {
    private let client: APIClient
    init(baseURL: URL) { client = APIClient(baseURL: baseURL) }
    func fetchSkills() async throws -> [Skill] { let response: SkillListResponse = try await client.request(.skills); return response.skills }
    func enableSkill(_ skill: Skill) async throws { try await set(skill, true) }
    func disableSkill(_ skill: Skill) async throws { try await set(skill, false) }
    private func set(_ skill: Skill, _ enabled: Bool) async throws {
        let _: StatusResponse = try await client.request(.skill(id: skill.id), method: "PATCH", body: JSONEncoder().encode(SkillToggle(enabled: enabled)))
    }
}
