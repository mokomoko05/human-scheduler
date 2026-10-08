import Foundation

public enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekdays, weekly, monthly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "不重复"
        case .daily: return "每天"
        case .weekdays: return "工作日"
        case .weekly: return "每周"
        case .monthly: return "每月"
        }
    }

    public func nextDate(after date: Date, monthDay: Int? = nil) -> Date? {
        let calendar = JournalDates.calendar
        switch self {
        case .none: return nil
        case .daily: return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date)
        case .weekdays:
            var next = calendar.date(byAdding: .day, value: 1, to: date)!
            while calendar.isDateInWeekend(next) { next = calendar.date(byAdding: .day, value: 1, to: next)! }
            return next
        case .monthly:
            let month = calendar.date(byAdding: .month, value: 1, to: JournalDates.monthStart(date))!
            let day = min(monthDay ?? calendar.component(.day, from: date), calendar.range(of: .day, in: .month, for: month)!.count)
            return calendar.date(byAdding: .day, value: day - 1, to: month)
        }
    }
}

public struct ScheduledTask: Identifiable {
    public let date: Date
    public let task: Todo
    public var id: UUID { task.id }

    public init(date: Date, task: Todo) {
        self.date = date
        self.task = task
    }

    /// 左侧清单和日历格子共用的顺序：手动位置优先，否则按截止时间，再按编号（排序不稳定，所以必须有最后的决胜条件）。
    public static func listOrder(_ lhs: ScheduledTask, _ rhs: ScheduledTask) -> Bool {
        let (a, b) = (lhs.task.sortKey, rhs.task.sortKey)
        if a != b { return a < b }
        let (x, y) = (lhs.task.number ?? .max, rhs.task.number ?? .max)
        return x != y ? x < y : lhs.task.id.uuidString < rhs.task.id.uuidString
    }
}

public enum AgendaFilter: String, CaseIterable, Identifiable {
    case unfinished, upcoming, overdue, all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .unfinished: return "未完成"
        case .upcoming: return "即将截止"
        case .overdue: return "已逾期"
        case .all: return "全部"
        }
    }

    public func includes(_ task: Todo, now: Date) -> Bool {
        switch self {
        case .all: return true
        case .unfinished: return !task.completed
        case .overdue: return !task.completed && task.effectiveDeadline.map { $0 < now } == true
        case .upcoming:
            guard !task.completed, let deadline = task.effectiveDeadline else { return false }
            let end = JournalDates.calendar.date(byAdding: .day, value: 7, to: now)!
            return deadline >= now && deadline <= end
        }
    }
}

public struct ReminderPlan: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let fireDate: Date
    public let dayKey: String
    public let taskID: UUID

    public static func pending(days: [String: DayEntry], now: Date = Date()) -> [ReminderPlan] {
        days.flatMap { key, entry in
            entry.todos.compactMap { task -> ReminderPlan? in
                guard !task.completed, let due = task.dueDate, let minutes = task.reminderMinutes else { return nil }
                let base = task.dueHasTime ? due : JournalDates.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: due)!
                let fire = base.addingTimeInterval(-Double(minutes) * 60)
                guard fire > now else { return nil }
                return ReminderPlan(id: "dayleaf.\(task.id.uuidString)", title: String(TaskText.rendered(task.title).characters), fireDate: fire, dayKey: JournalDates.key(due), taskID: task.id)
            }
        }.sorted { $0.fireDate < $1.fireDate }
    }
}

public struct BackupRecord: Identifiable {
    public let url: URL
    public let date: Date
    public var id: String { url.path }
}

public struct BackupPreview {
    public let dayCount: Int
    public let taskCount: Int
    public let summaryCount: Int
    public let logCount: Int
}
