@preconcurrency import EventKit
import Foundation

@MainActor
final class EventKitCapability {
    private let store = EKEventStore()

    var permissionStatus: [String: String] {
        ["calendar": status(.event), "reminders": status(.reminder)]
    }

    private func status(_ entity: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized, .fullAccess: "fullAccess"
        case .writeOnly: "writeOnly"
        @unknown default: "unknown"
        }
    }

    private func ensureAccess(_ entity: EKEntityType) async throws {
        let current = EKEventStore.authorizationStatus(for: entity)
        if current == .fullAccess { return }
        if current == .denied || current == .restricted { throw NativeActionError(code: "PERMISSION_DENIED", message: entity == .event ? "请在系统设置的隐私与安全性中允许 Ark 访问日历" : "请在系统设置的隐私与安全性中允许 Ark 访问提醒事项") }
        let granted = try await (entity == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())
        guard granted else { throw NativeActionError(code: "PERMISSION_DENIED", message: "没有获得系统权限") }
    }

    func prepare(action: String, arguments: [String: JSONValue]) async throws -> (preview: [String: JSONValue], read: [String: JSONValue]?) {
        if action.hasPrefix("calendar.") { try await ensureAccess(.event); return try prepareCalendar(action, arguments) }
        if action.hasPrefix("reminders.") { try await ensureAccess(.reminder); return try await prepareReminder(action, arguments) }
        throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "不支持的 EventKit 动作")
    }

    func execute(action: String, arguments: [String: JSONValue], readResult: [String: JSONValue]?) async throws -> [String: JSONValue] {
        if let readResult { return readResult }
        if action.hasPrefix("calendar.") { try await ensureAccess(.event); return try executeCalendar(action, arguments) }
        if action.hasPrefix("reminders.") { try await ensureAccess(.reminder); return try executeReminder(action, arguments) }
        throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "不支持的 EventKit 动作")
    }

    private func prepareCalendar(_ action: String, _ arguments: [String: JSONValue]) throws -> (preview: [String: JSONValue], read: [String: JSONValue]?) {
        switch action {
        case "calendar.list_calendars":
            let values = store.calendars(for: .event).map { calendar in JSONValue.object(["id": .string(calendar.calendarIdentifier), "title": .string(calendar.title), "writable": .bool(calendar.allowsContentModifications)]) }
            return (["summary": .string("查看日历列表")], ["calendars": .array(values), "verified": .bool(true)])
        case "calendar.list_events":
            let start = try NativeDates.parse(arguments.requiredString("start")), end = try NativeDates.parse(arguments.requiredString("end"))
            guard end > start, end.timeIntervalSince(start) <= 31 * 86_400 else { throw NativeActionError(code: "INVALID_ARGUMENT", message: "查询时间范围必须大于零且不超过 31 天") }
            var calendars: [EKCalendar]? = nil
            if let id = arguments.optionalString("calendar_id") {
                guard let calendar = store.calendar(withIdentifier: id) else { throw NativeActionError(code: "TARGET_NOT_FOUND", message: "找不到指定日历") }
                calendars = [calendar]
            }
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars)).prefix(50).map(eventJSON)
            return (["summary": .string("查询指定时间范围内的日程")], ["events": .array(events.map(JSONValue.object)), "truncated": .bool(events.count == 50), "verified": .bool(true)])
        case "calendar.create_event":
            let title = try arguments.requiredString("title"), calendar = try writableCalendar(arguments)
            let (start, end, timezone) = try eventTimes(arguments)
            return (["summary": .string("在“\(calendar.title)”新建“\(title)”"), "before": .null, "after": .object(["title": .string(title), "start": NativeDates.string(start), "end": NativeDates.string(end), "timezone": .string(timezone.identifier), "all_day": .bool(arguments.optionalBool("all_day") ?? false)])], nil)
        case "calendar.update_event", "calendar.delete_event":
            let event = try existingEvent(arguments)
            let before = eventJSON(event)
            if action.hasSuffix("delete_event") { return (["summary": .string("删除日程“\(event.title ?? "未命名")”"), "before": .object(before), "after": .null], nil) }
            var after = before
            if let title = arguments.optionalString("title") { after["title"] = .string(title) }
            if arguments["start"] != nil || arguments["end"] != nil {
                let (start, end, timezone) = try eventTimes(arguments)
                after["start"] = NativeDates.string(start); after["end"] = NativeDates.string(end); after["timezone"] = .string(timezone.identifier)
            }
            if let allDay = arguments.optionalBool("all_day") { after["all_day"] = .bool(allDay) }
            return (["summary": .string("修改日程“\(event.title ?? "未命名")”"), "before": .object(before), "after": .object(after)], nil)
        default: throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "不支持的日历动作")
        }
    }

    private func executeCalendar(_ action: String, _ arguments: [String: JSONValue]) throws -> [String: JSONValue] {
        switch action {
        case "calendar.create_event":
            let event = EKEvent(eventStore: store)
            event.title = try arguments.requiredString("title"); event.calendar = try writableCalendar(arguments)
            let (start, end, timezone) = try eventTimes(arguments)
            event.startDate = start; event.endDate = end; event.timeZone = timezone; event.isAllDay = arguments.optionalBool("all_day") ?? false
            try store.save(event, span: .thisEvent, commit: true)
            guard let saved = store.event(withIdentifier: event.eventIdentifier) else { throw NativeActionError(code: "RESULT_UNKNOWN", message: "系统已接受保存，但无法读回日程") }
            return ["event": .object(eventJSON(saved)), "verified": .bool(true)]
        case "calendar.update_event":
            let event = try existingEvent(arguments)
            if let title = arguments.optionalString("title") { event.title = title }
            if arguments["start"] != nil || arguments["end"] != nil {
                let (start, end, timezone) = try eventTimes(arguments); event.startDate = start; event.endDate = end; event.timeZone = timezone
            }
            if let allDay = arguments.optionalBool("all_day") { event.isAllDay = allDay }
            try store.save(event, span: .thisEvent, commit: true)
            guard let saved = store.event(withIdentifier: event.eventIdentifier) else { throw NativeActionError(code: "RESULT_UNKNOWN", message: "修改可能成功，但无法读回日程") }
            return ["event": .object(eventJSON(saved)), "verified": .bool(true)]
        case "calendar.delete_event":
            let event = try existingEvent(arguments), id = event.eventIdentifier ?? ""
            try store.remove(event, span: .thisEvent, commit: true)
            return ["event_id": .string(id), "verified": .bool(store.event(withIdentifier: id) == nil)]
        default: throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "日历查询应使用准备阶段的结果")
        }
    }

    private func writableCalendar(_ arguments: [String: JSONValue]) throws -> EKCalendar {
        let id = try arguments.requiredString("calendar_id")
        guard let calendar = store.calendar(withIdentifier: id) else { throw NativeActionError(code: "TARGET_NOT_FOUND", message: "找不到指定日历") }
        guard calendar.allowsContentModifications else { throw NativeActionError(code: "PERMISSION_DENIED", message: "指定日历只读") }
        return calendar
    }

    private func eventTimes(_ arguments: [String: JSONValue]) throws -> (Date, Date, TimeZone) {
        let start = try NativeDates.parse(arguments.requiredString("start")), end = try NativeDates.parse(arguments.requiredString("end"))
        guard end > start else { throw NativeActionError(code: "INVALID_ARGUMENT", message: "结束时间必须晚于开始时间") }
        let zoneName = try arguments.requiredString("timezone")
        guard let zone = TimeZone(identifier: zoneName) else { throw NativeActionError(code: "INVALID_ARGUMENT", message: "无效时区") }
        return (start, end, zone)
    }

    private func existingEvent(_ arguments: [String: JSONValue]) throws -> EKEvent {
        let id = try arguments.requiredString("event_id"), expected = try arguments.requiredString("expected_version")
        guard let event = store.event(withIdentifier: id) else { throw NativeActionError(code: "TARGET_NOT_FOUND", message: "日程已不存在") }
        guard event.recurrenceRules?.isEmpty != false else { throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "首版不自动修改重复日程") }
        guard version(event) == expected else { throw NativeActionError(code: "CONFLICT", message: "日程已在其他位置更改，请重新查询") }
        guard event.calendar.allowsContentModifications else { throw NativeActionError(code: "PERMISSION_DENIED", message: "日历只读") }
        return event
    }

    private func version(_ item: EKCalendarItem) -> String { NativeDates.formatter.string(from: item.lastModifiedDate ?? item.creationDate ?? .distantPast) }
    private func eventJSON(_ event: EKEvent) -> [String: JSONValue] {
        ["event_id": .string(event.eventIdentifier ?? ""), "version": .string(version(event)), "title": .string(event.title ?? ""), "start": NativeDates.string(event.startDate), "end": NativeDates.string(event.endDate), "timezone": .string(event.timeZone?.identifier ?? TimeZone.current.identifier), "all_day": .bool(event.isAllDay), "calendar_id": .string(event.calendar.calendarIdentifier), "calendar": .string(event.calendar.title), "recurring": .bool(event.recurrenceRules?.isEmpty == false)]
    }

    private func prepareReminder(_ action: String, _ arguments: [String: JSONValue]) async throws -> (preview: [String: JSONValue], read: [String: JSONValue]?) {
        switch action {
        case "reminders.list_lists":
            let values = store.calendars(for: .reminder).map { JSONValue.object(["id": .string($0.calendarIdentifier), "title": .string($0.title), "writable": .bool($0.allowsContentModifications)]) }
            return (["summary": .string("查看提醒事项列表")], ["lists": .array(values), "verified": .bool(true)])
        case "reminders.list_reminders":
            let calendar = try reminderCalendar(arguments)
            let reminders = await fetchReminders(in: calendar).filter { arguments.optionalBool("include_completed") == true || !$0.isCompleted }.prefix(50).map(reminderJSON)
            return (["summary": .string("查询“\(calendar.title)”中的提醒事项")], ["reminders": .array(reminders.map(JSONValue.object)), "truncated": .bool(reminders.count == 50), "verified": .bool(true)])
        case "reminders.create_reminder":
            let calendar = try reminderCalendar(arguments), title = try arguments.requiredString("title")
            var after: [String: JSONValue] = ["title": .string(title), "list": .string(calendar.title)]
            if let due = arguments.optionalString("due") { after["due"] = .string(due); _ = try reminderDueComponents(arguments) }
            return (["summary": .string("在“\(calendar.title)”新建提醒“\(title)”"), "before": .null, "after": .object(after)], nil)
        case "reminders.update_reminder", "reminders.complete_reminder", "reminders.delete_reminder":
            let reminder = try existingReminder(arguments), before = reminderJSON(reminder)
            if action.hasSuffix("complete_reminder") { return (["summary": .string("完成提醒“\(reminder.title ?? "未命名")”"), "before": .object(before), "after": .object(before.merging(["completed": .bool(true)]) { _, new in new })], nil) }
            if action.hasSuffix("delete_reminder") { return (["summary": .string("删除提醒“\(reminder.title ?? "未命名")”"), "before": .object(before), "after": .null], nil) }
            var after = before
            if let title = arguments.optionalString("title") { after["title"] = .string(title) }
            if let due = arguments.optionalString("due") { after["due"] = .string(due); _ = try reminderDueComponents(arguments) }
            return (["summary": .string("修改提醒“\(reminder.title ?? "未命名")”"), "before": .object(before), "after": .object(after)], nil)
        default: throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "不支持的提醒事项动作")
        }
    }

    private func executeReminder(_ action: String, _ arguments: [String: JSONValue]) throws -> [String: JSONValue] {
        let reminder: EKReminder
        if action == "reminders.create_reminder" {
            reminder = EKReminder(eventStore: store); reminder.title = try arguments.requiredString("title"); reminder.calendar = try reminderCalendar(arguments)
        } else { reminder = try existingReminder(arguments) }
        switch action {
        case "reminders.create_reminder", "reminders.update_reminder":
            if let title = arguments.optionalString("title") { reminder.title = title }
            if arguments.optionalString("due") != nil { reminder.dueDateComponents = try reminderDueComponents(arguments) }
            try store.save(reminder, commit: true)
            guard let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { throw NativeActionError(code: "RESULT_UNKNOWN", message: "系统已接受保存，但无法读回提醒事项") }
            return ["reminder": .object(reminderJSON(saved)), "verified": .bool(true)]
        case "reminders.complete_reminder":
            reminder.isCompleted = true; reminder.completionDate = Date(); try store.save(reminder, commit: true)
            guard let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { throw NativeActionError(code: "RESULT_UNKNOWN", message: "完成操作可能成功，但无法读回") }
            return ["reminder": .object(reminderJSON(saved)), "verified": .bool(saved.isCompleted)]
        case "reminders.delete_reminder":
            let id = reminder.calendarItemIdentifier; try store.remove(reminder, commit: true)
            return ["reminder_id": .string(id), "verified": .bool(store.calendarItem(withIdentifier: id) == nil)]
        default: throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "提醒事项查询应使用准备阶段的结果")
        }
    }

    private func reminderCalendar(_ arguments: [String: JSONValue]) throws -> EKCalendar {
        let id = try arguments.requiredString("list_id")
        guard let calendar = store.calendar(withIdentifier: id) else { throw NativeActionError(code: "TARGET_NOT_FOUND", message: "找不到提醒事项列表") }
        guard calendar.type != .birthday, calendar.allowsContentModifications else { throw NativeActionError(code: "PERMISSION_DENIED", message: "提醒事项列表只读") }
        return calendar
    }

    private func existingReminder(_ arguments: [String: JSONValue]) throws -> EKReminder {
        let id = try arguments.requiredString("reminder_id"), expected = try arguments.requiredString("expected_version")
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw NativeActionError(code: "TARGET_NOT_FOUND", message: "提醒事项已不存在") }
        guard reminder.recurrenceRules?.isEmpty != false else { throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "首版不自动修改重复提醒") }
        guard version(reminder) == expected else { throw NativeActionError(code: "CONFLICT", message: "提醒事项已改变，请重新查询") }
        guard reminder.calendar.allowsContentModifications else { throw NativeActionError(code: "PERMISSION_DENIED", message: "提醒事项列表只读") }
        return reminder
    }

    private func reminderDueComponents(_ arguments: [String: JSONValue]) throws -> DateComponents {
        let date = try NativeDates.parse(arguments.requiredString("due")), zoneName = try arguments.requiredString("timezone")
        guard let zone = TimeZone(identifier: zoneName) else { throw NativeActionError(code: "INVALID_ARGUMENT", message: "无效时区") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let fields: Set<Calendar.Component> = arguments.optionalBool("date_only") == true ? [.year, .month, .day, .calendar, .timeZone] : [.year, .month, .day, .hour, .minute, .second, .calendar, .timeZone]
        return calendar.dateComponents(fields, from: date)
    }

    private func fetchReminders(in calendar: EKCalendar) async -> [EKReminder] {
        let wrapped = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: [calendar])) {
                continuation.resume(returning: UncheckedReminders(value: $0 ?? []))
            }
        }
        return wrapped.value
    }

    private func reminderJSON(_ reminder: EKReminder) -> [String: JSONValue] {
        var result: [String: JSONValue] = ["reminder_id": .string(reminder.calendarItemIdentifier), "version": .string(version(reminder)), "title": .string(reminder.title ?? ""), "list_id": .string(reminder.calendar.calendarIdentifier), "list": .string(reminder.calendar.title), "completed": .bool(reminder.isCompleted), "recurring": .bool(reminder.recurrenceRules?.isEmpty == false)]
        if let components = reminder.dueDateComponents { result["due"] = components.date.map { NativeDates.string($0) } ?? .null; result["timezone"] = .string(components.timeZone?.identifier ?? TimeZone.current.identifier) }
        return result
    }
}

// EventKit returns these objects through a legacy completion handler. The capability is
// MainActor-isolated and unwraps them only after resuming on that actor.
private struct UncheckedReminders: @unchecked Sendable { let value: [EKReminder] }
