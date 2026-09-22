import SwiftUI

struct NotificationSummaryResult: Decodable, Sendable {
    let summary: String
    let total: Int
    let unknown_time_count: Int
    let coverage: String
    let model: String
    let events: [ArkNotificationEvent]
}

@MainActor
final class NotificationSummaryViewModel: ObservableObject {
    @Published var start = Date().addingTimeInterval(-3600)
    @Published var end = Date()
    @Published var sourceApp = ""
    @Published var consent = false
    @Published var isBusy = false
    @Published var progress = ""
    @Published var warning = ""
    @Published var error: String?
    @Published var result: NotificationSummaryResult?
    private let client: APIClient
    private let adapter: any ApplicationEventAdapter
    private var task: Task<Void, Never>?

    init(baseURL: URL, adapter: any ApplicationEventAdapter = NotificationCenterAXAdapter()) {
        client = APIClient(baseURL: baseURL); self.adapter = adapter
    }

    var validRange: Bool { end > start && end.timeIntervalSince(start) <= 31 * 86400 }

    func summarize(capture: Bool) {
        guard !isBusy, validRange, !capture || consent else { return }
        isBusy = true; error = nil; result = nil; warning = ""
        let windowStart = start, windowEnd = end, app = sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task {
            defer { isBusy = false; task = nil }
            do {
                struct SkillStatus: Decodable { let isEnabled: Bool }
                let skill: SkillStatus = try await client.request(.skill(id: "ark.notifications"))
                guard skill.isEnabled else { throw APIError.server("请先在 Skill 管理启用“通知感知与总结”。") }
                if capture {
                    progress = "正在读取通知中心…"
                    let captured = try await adapter.capture()
                    warning = captured.warning
                    struct CapturePayload: Encodable { let events: [ArkNotificationEvent] }
                    struct CaptureReply: Decodable { let inserted: Int }
                    var inserted = 0
                    // Bound each payload below the local API's 64 KiB request limit.
                    for event in captured.events {
                        try Task.checkCancellation()
                        let reply: CaptureReply = try await client.request(.notificationCapture, method: "POST", body: JSONEncoder().encode(CapturePayload(events: [event])))
                        inserted += reply.inserted
                    }
                    let unknown = captured.events.filter { $0.occurred_at == nil }.count
                    warning += " 本次读取 \(captured.events.count) 条，新增 \(inserted) 条，\(unknown) 条接收时间不明。"
                }
                try Task.checkCancellation()
                progress = "本地模型正在总结；通知较多时会分组处理…"
                struct Window: Encodable { let start: String; let end: String; let source_app: String? }
                result = try await client.request(.notificationSummary, method: "POST", body: JSONEncoder().encode(Window(start: windowStart.ISO8601Format(), end: windowEnd.ISO8601Format(), source_app: app.isEmpty ? nil : app)))
                progress = "已完成"
            } catch is CancellationError { progress = "已取消" }
            catch { self.error = error.localizedDescription; progress = "" }
        }
    }

    func clearHistory() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            struct Reply: Decodable { let status: String }
            let _: Reply = try await client.request(.notificationHistory, method: "DELETE")
            result = nil; warning = ""; error = nil; progress = "已清空通知采集库"
        } catch { self.error = error.localizedDescription }
    }
}

struct NotificationSummaryView: View {
    @ObservedObject var viewModel: NotificationSummaryViewModel
    @State private var confirmsClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("将分散的通知整理成一份摘要")
                    .font(.title2.bold())
                Text("选择时间段，手动读取通知中心，再由本地模型整理重点与待办。微信和其他应用共用同一采集流程。")
                    .foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("最近 1 小时") { preset(hours: 1) }
                            Button("最近 24 小时") { preset(hours: 24) }
                            Button("今天") { viewModel.end = Date(); viewModel.start = Calendar.current.startOfDay(for: Date()) }
                        }
                        DatePicker("开始", selection: $viewModel.start, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("结束", selection: $viewModel.end, displayedComponents: [.date, .hourAndMinute])
                        TextField("应用名称（留空为全部，例如 微信）", text: $viewModel.sourceApp)
                            .textFieldStyle(.roundedBorder)
                        Text("按通知接收时间筛选，包含开始、不包含结束；使用 Mac 当前时区。最多 31 天。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }.disabled(viewModel.isBusy)
                Toggle("允许本次手动采集，并将通知保存在本机供总结", isOn: $viewModel.consent)
                    .disabled(viewModel.isBusy)
                HStack {
                    Button("辅助功能授权", systemImage: "hand.raised") { NotificationCenterAXAdapter.requestPermission() }
                    Spacer()
                    Button("总结已采集记录") { viewModel.summarize(capture: false) }
                    Button("智能总结", systemImage: "sparkles") { viewModel.summarize(capture: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.consent)
                }.disabled(viewModel.isBusy || !viewModel.validRange)
                Text("第一阶段不会常驻监听。只能读取通知中心暴露的内容，已清除、折叠和隐藏预览的通知可能缺失。请展开所需通知分组；时间不明的内容不会计入时间段摘要。本机记录保留 30 天，可随时清空。")
                    .font(.callout).foregroundStyle(.secondary)
                if viewModel.isBusy {
                    HStack { ProgressView().controlSize(.small); Text(viewModel.progress) }
                }
                if !viewModel.warning.isEmpty { Text(viewModel.warning).font(.callout).foregroundStyle(.orange) }
                if let error = viewModel.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let result = viewModel.result {
                    Divider()
                    Text("\(result.total) 条通知 · \(result.model)").font(.headline)
                    Text(result.coverage).font(.caption).foregroundStyle(.secondary)
                    if result.unknown_time_count > 0 {
                        Text("此期间采集的另有 \(result.unknown_time_count) 条通知时间不明，未纳入摘要。")
                            .foregroundStyle(.orange)
                    }
                    Text(result.summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    DisclosureGroup("核对原始通知") {
                        ForEach(Array(result.events.enumerated()), id: \.offset) { _, event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(event.source_app) · \(event.title)").font(.headline)
                                Text(event.body)
                                Text("\(event.occurred_at ?? "时间不明") · \(event.time_precision == "approximate" ? "约" : "") · \(String((event.id ?? "").prefix(8)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.textSelection(.enabled).padding(.vertical, 6)
                        }
                    }
                }
                Button("清空通知采集库", role: .destructive) { confirmsClear = true }
                    .disabled(viewModel.isBusy)
                if !viewModel.isBusy && viewModel.result == nil && !viewModel.progress.isEmpty { Text(viewModel.progress).foregroundStyle(.secondary) }
            }.padding(28).frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("智能总结")
        .confirmationDialog("清空通知采集库？系统通知中心和对话中已引用的内容不受影响。", isPresented: $confirmsClear) {
            Button("清空", role: .destructive) { Task { await viewModel.clearHistory() } }
        }
    }

    private func preset(hours: Double) { viewModel.end = Date(); viewModel.start = viewModel.end.addingTimeInterval(-hours * 3600) }
}
