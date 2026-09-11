import SwiftUI

struct TaskPanelView: View {
    @ObservedObject var viewModel: ChatViewModel

    private var activeRuns: [BackgroundRun] {
        viewModel.backgroundRuns.reversed().filter(\.isActive)
    }

    private var recentRuns: [BackgroundRun] {
        Array(viewModel.backgroundRuns.reversed().filter { !$0.isActive }.prefix(8))
    }

    private var waitingApprovalCount: Int {
        viewModel.toolActivities.count(where: { $0.state == .waitingApproval })
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            if viewModel.backgroundRuns.isEmpty {
                ContentUnavailableView(
                    "暂无任务",
                    systemImage: "checklist",
                    description: Text("需要调用 Skill 时，任务进度和确认操作会显示在这里。")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !activeRuns.isEmpty {
                            sectionTitle("运行中", count: activeRuns.count)
                            ForEach(activeRuns) { run in
                                TaskDetailCard(
                                    run: run,
                                    activities: activities(for: run),
                                    onCancel: { Task { await viewModel.cancel(run) } },
                                    onApproval: { activity, approved in
                                        Task { await viewModel.resolveApproval(for: activity, approved: approved) }
                                    }
                                )
                                .id("active-\(run.id)")
                            }
                        }
                        if !recentRuns.isEmpty {
                            sectionTitle("最近完成", count: recentRuns.count)
                            ForEach(recentRuns) { run in
                                TaskDetailCard(
                                    run: run,
                                    activities: activities(for: run),
                                    onCancel: {},
                                    onApproval: { _, _ in }
                                )
                                .id("recent-\(run.id)")
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var panelHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("任务", systemImage: "tray.full")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.activeRunCount) 运行中")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if waitingApprovalCount > 0 {
                Label("\(waitingApprovalCount) 项操作等待确认", systemImage: "exclamationmark.shield.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            } else {
                Text("任务在后台执行，对话可以继续。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .textCase(.uppercase)
    }

    private func activities(for run: BackgroundRun) -> [ToolActivity] {
        guard let runID = run.runID else { return [] }
        return viewModel.toolActivities.filter { $0.runID == runID }
    }
}

private struct TaskDetailCard: View {
    let run: BackgroundRun
    let activities: [ToolActivity]
    let onCancel: () -> Void
    let onApproval: (ToolActivity, Bool) -> Void
    @State private var isExpanded: Bool

    init(
        run: BackgroundRun,
        activities: [ToolActivity],
        onCancel: @escaping () -> Void,
        onApproval: @escaping (ToolActivity, Bool) -> Void
    ) {
        self.run = run
        self.activities = activities
        self.onCancel = onCancel
        self.onApproval = onApproval
        _isExpanded = State(initialValue: run.isActive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                statusSymbol
                statusBadge
                Spacer()
                if run.isActive, run.runID != nil {
                    Button("取消", systemImage: "stop.circle", action: onCancel)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("取消这个后台任务")
                }
            }

            Text(run.request)
                .font(.subheadline.weight(.medium))
                .lineLimit(isExpanded ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(run.detail)
                .font(.caption)
                .foregroundStyle(run.error == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)

            if let runID = run.runID {
                HStack(spacing: 6) {
                    Text(String(runID.prefix(8)))
                    Text("·")
                    Text(run.startedAt, style: .time)
                    if !activities.isEmpty {
                        Text("·")
                        Text("\(activities.count) 次调用")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }

            if !activities.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                            SkillStepRow(
                                number: index + 1,
                                activity: activity,
                                onApproval: { onApproval(activity, $0) }
                            )
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Skill 调用序列")
                        .font(.caption.bold())
                }
                .tint(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusColor.opacity(run.isActive ? 0.35 : 0.14), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var statusSymbol: some View {
        if run.isActive {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: run.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(statusColor)
        }
    }

    private var statusBadge: some View {
        Text(statusTitle)
            .font(.caption2.bold())
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var hasWaitingApproval: Bool {
        activities.contains(where: { $0.state == .waitingApproval })
    }

    private var statusTitle: String {
        if hasWaitingApproval { return "等待确认" }
        if !run.isActive { return run.error == nil ? "已完成" : "失败" }
        return [
            "queued": "排队中",
            "retrieving_memory": "检索记忆",
            "waiting_model": "等待模型",
            "planning": "规划中",
            "preparing": "准备操作",
            "waiting_approval": "等待确认",
            "executing": "执行中",
            "verifying": "核验结果"
        ][run.stage] ?? "运行中"
    }

    private var statusColor: Color {
        if hasWaitingApproval { return .orange }
        if run.error != nil { return .red }
        if run.isActive { return .blue }
        return .green
    }
}

private struct SkillStepRow: View {
    let number: Int
    let activity: ToolActivity
    let onApproval: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(stepColor)
                .frame(width: 20, height: 20)
                .background(stepColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(actionTitle).font(.caption.bold())
                    Spacer()
                    Label(stateTitle, systemImage: stateIcon)
                        .font(.caption2)
                        .foregroundStyle(stepColor)
                        .labelStyle(.titleAndIcon)
                }
                Text(activity.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let preview = activity.preview {
                    PreviewDetails(preview: preview)
                }

                if activity.state == .waitingApproval {
                    HStack {
                        Button("拒绝", role: .cancel) { onApproval(false) }
                            .buttonStyle(.bordered)
                        Button("确认执行") { onApproval(true) }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var actionTitle: String {
        [
            "applications.find_apps": "查找应用",
            "applications.list_running_apps": "读取运行中应用",
            "applications.open_app": "打开应用",
            "applications.activate_app": "切换到应用",
            "applications.quit_app": "退出应用",
            "calendar.list_calendars": "读取日历列表",
            "calendar.list_events": "查询日程",
            "calendar.create_event": "新建日程",
            "calendar.update_event": "修改日程",
            "calendar.delete_event": "删除日程",
            "reminders.list_lists": "读取提醒列表",
            "reminders.list_reminders": "查询提醒",
            "reminders.create_reminder": "新建提醒",
            "reminders.update_reminder": "修改提醒",
            "reminders.complete_reminder": "完成提醒",
            "reminders.delete_reminder": "删除提醒",
            "web.search": "搜索互联网",
            "web.fetch_page": "读取网页",
            "example.echo": "示例回显"
        ][activity.actionID] ?? activity.actionID
    }

    private var stateTitle: String {
        switch activity.state {
        case .preparing: "准备"
        case .waitingApproval: "待确认"
        case .executing: "执行"
        case .succeeded: "成功"
        case .failed: "失败"
        }
    }

    private var stateIcon: String {
        switch activity.state {
        case .preparing: "ellipsis.circle"
        case .waitingApproval: "exclamationmark.shield"
        case .executing: "gearshape.2"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var stepColor: Color {
        switch activity.state {
        case .waitingApproval: .orange
        case .succeeded: .green
        case .failed: .red
        default: .blue
        }
    }
}

private struct PreviewDetails: View {
    let preview: [String: JSONValue]

    private var keys: [String] {
        let priority = ["summary", "before", "after", "arguments"]
        return preview.keys
            .filter { $0 != "preview_token" }
            .sorted {
                (priority.firstIndex(of: $0) ?? priority.count) < (priority.firstIndex(of: $1) ?? priority.count)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(keys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label(for: key))
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Text(preview[key]?.displayText ?? "")
                        .font(.caption2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func label(for key: String) -> String {
        [
            "summary": "操作",
            "before": "修改前",
            "after": "修改后",
            "arguments": "参数"
        ][key] ?? key
    }
}
