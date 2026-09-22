import Foundation

private struct BridgeHello: Encodable {
    let type = "hello"
    let protocolVersion: String
    let actions: [String]
    let digests: [String: String]
    let permissions: [String: String]
    enum CodingKeys: String, CodingKey { case type, actions, digests, permissions; case protocolVersion = "protocol_version" }
}

private struct BridgePermissions: Encodable {
    let type = "permissions"
    let permissions: [String: String]
}

@MainActor
final class NativeCapabilityHost: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    private let baseURL: URL
    private let applications = ApplicationCapability()
    private let eventKit = EventKitCapability()
    private let notifications = NotificationCapability()
    private var permissionStatus: [String: String] {
        eventKit.permissionStatus.merging(["accessibility": NotificationCenterAXAdapter.isTrusted ? "authorized" : "notDetermined"]) { _, new in new }
    }
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var prepared: [String: PreparedNativeAction] = [:]

    init(baseURL: URL) { self.baseURL = baseURL }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var retrySeconds = 2
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.connectAndServe()
                    retrySeconds = 2
                }
                catch is CancellationError { return }
                catch {
                    let hadConnection = self.isConnected
                    self.lastError = error.localizedDescription; self.isConnected = false
                    print("[NativeCapabilityHost] \(error.localizedDescription)")
                    retrySeconds = hadConnection ? 2 : min(retrySeconds * 2, 30)
                }
                try? await Task.sleep(for: .seconds(retrySeconds))
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        isConnected = false
    }

    private func connectAndServe() async throws {
        let catalog = try loadCatalog()
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/native/bridge"
        guard let url = components?.url else { throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "原生桥接地址无效") }
        let token = try loadToken()
        var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket; socket.resume()
        try await send(BridgeHello(protocolVersion: catalog.protocolVersion, actions: catalog.actions, digests: catalog.digests, permissions: permissionStatus), over: socket)
        let ready = try await receiveDictionary(from: socket)
        guard ready["type"] as? String == "ready" else { throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "原生能力握手失败") }
        isConnected = true; lastError = nil
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: continue
            }
            do {
                let request = try JSONDecoder().decode(NativeRequest.self, from: data)
                let response = try await handle(request)
                try await send(response, over: socket)
            } catch {
                let request = try? JSONDecoder().decode(NativeRequest.self, from: data)
                let native = error as? NativeActionError
                let response = NativeResponse(messageID: request?.messageID ?? "", status: "failed", data: nil, error: NativeErrorBody(code: native?.code ?? "EXECUTION_FAILED", message: error.localizedDescription))
                try await send(response, over: socket)
            }
            try await send(BridgePermissions(permissions: permissionStatus), over: socket)
        }
    }

    private func handle(_ request: NativeRequest) async throws -> NativeResponse {
        guard request.deadline > Date().timeIntervalSince1970 else { throw NativeActionError(code: "TIMEOUT", message: "执行请求已过期") }
        if request.operation == "prepare" {
            prepared = prepared.filter { $0.value.expiresAt > Date() }
            let value: (preview: [String: JSONValue], read: [String: JSONValue]?)
            if request.actionID.hasPrefix("applications.") { value = try await applications.prepare(action: request.actionID, arguments: request.arguments) }
            else if request.actionID == "notifications.capture" { value = notifications.prepare() }
            else { value = try await eventKit.prepare(action: request.actionID, arguments: request.arguments) }
            let token = UUID().uuidString
            prepared[token] = PreparedNativeAction(actionID: request.actionID, arguments: request.arguments, expiresAt: Date().addingTimeInterval(300), readResult: value.read)
            var preview = value.preview; preview["preview_token"] = .string(token)
            return NativeResponse(messageID: request.messageID, status: "succeeded", data: preview, error: nil)
        }
        guard request.operation == "execute", let token = request.previewToken, let item = prepared.removeValue(forKey: token), item.expiresAt > Date(), item.actionID == request.actionID, item.arguments == request.arguments else {
            throw NativeActionError(code: "CONFLICT", message: "操作预览已过期或参数发生变化")
        }
        let result: [String: JSONValue]
        if request.actionID.hasPrefix("applications.") { result = try await applications.execute(action: request.actionID, arguments: request.arguments, readResult: item.readResult) }
        else if request.actionID == "notifications.capture" { result = try await notifications.execute() }
        else { result = try await eventKit.execute(action: request.actionID, arguments: request.arguments, readResult: item.readResult) }
        return NativeResponse(messageID: request.messageID, status: "succeeded", data: result, error: nil)
    }

    private func loadCatalog() throws -> NativeCatalog {
        let url = Bundle.module.url(forResource: "native-capabilities", withExtension: "json", subdirectory: "Resources") ?? Bundle.module.url(forResource: "native-capabilities", withExtension: "json")
        guard let url else { throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "缺少原生能力清单") }
        return try JSONDecoder().decode(NativeCatalog.self, from: Data(contentsOf: url))
    }

    private func loadToken() throws -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("ArkIntelligence/runtime/token")
        guard let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 32 else { throw APIError.authenticationUnavailable }
        return value
    }

    private func send<T: Encodable>(_ value: T, over socket: URLSessionWebSocketTask) async throws { try await socket.send(.data(JSONEncoder().encode(value))) }
    private func receiveDictionary(from socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive(), data: Data
        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: data = Data() }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "原生握手响应无效") }
        return object
    }
}
