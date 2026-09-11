import Foundation

struct NativeCatalog: Codable {
    let protocolVersion: String
    let digests: [String: String]
    let actions: [String]
    enum CodingKeys: String, CodingKey { case digests, actions; case protocolVersion = "protocol_version" }
}

struct NativeRequest: Decodable {
    let messageID: String
    let operation: String
    let actionID: String
    let callID: String
    let arguments: [String: JSONValue]
    let previewToken: String?
    let deadline: Double
    enum CodingKeys: String, CodingKey {
        case operation, arguments, deadline
        case messageID = "message_id"
        case actionID = "action_id"
        case callID = "call_id"
        case previewToken = "preview_token"
    }
}

struct NativeErrorBody: Codable { let code: String; let message: String }
struct NativeResponse: Codable {
    let type = "result"
    let messageID: String
    let status: String
    let data: [String: JSONValue]?
    let error: NativeErrorBody?
    enum CodingKeys: String, CodingKey { case type, status, data, error; case messageID = "message_id" }
}

struct PreparedNativeAction {
    let actionID: String
    let arguments: [String: JSONValue]
    let expiresAt: Date
    let readResult: [String: JSONValue]?
}

struct NativeActionError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

extension Dictionary where Key == String, Value == JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard case .string(let value)? = self[key], !value.isEmpty else { throw NativeActionError(code: "INVALID_ARGUMENT", message: "缺少参数：\(key)") }
        return value
    }
    func optionalString(_ key: String) -> String? { if case .string(let value)? = self[key] { value } else { nil } }
    func optionalBool(_ key: String) -> Bool? { if case .bool(let value)? = self[key] { value } else { nil } }
}

@MainActor
enum NativeDates {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let fallback = ISO8601DateFormatter()
    static func parse(_ value: String) throws -> Date {
        guard let date = formatter.date(from: value) ?? fallback.date(from: value) else { throw NativeActionError(code: "INVALID_ARGUMENT", message: "时间不是有效 ISO 8601 格式") }
        return date
    }
    static func string(_ date: Date?) -> JSONValue { date.map { .string(formatter.string(from: $0)) } ?? .null }
}
