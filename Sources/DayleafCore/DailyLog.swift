import Foundation

public enum DailyLogKind: String, Codable, CaseIterable, Identifiable {
    case note, done, block, plan
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .note: return "INFO"
        case .done: return "DONE"
        case .block: return "BLOCK"
        case .plan: return "PLAN"
        }
    }
    public var title: String {
        switch self {
        case .note: return "随手记录"
        case .done: return "进展"
        case .block: return "卡点"
        case .plan: return "明日计划"
        }
    }
}

public struct DailyLogEntry: Codable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var kind: DailyLogKind
    public var text: String
    public var taskID: UUID?
    public var taskTitle: String?
    public var taskNumber: Int?
    /// 记录日志时所关联待办的标签（快照）：待办被删除后，按标签仍然能找到这条日志。
    public var taskTags: [String]
    /// 图片文件名（位于数据目录的 Images 文件夹）。
    public var images: [String]
    /// 图片名 → 识别出的文字。没有该键表示尚未识别，空字符串表示识别过但没有文字。
    public var imageText: [String: String]
    /// 专注计时产生的开始、结束记录：显示在终端日志里，但不进入笔记视图。
    public var focus: Bool

    public init(id: UUID = UUID(), createdAt: Date, kind: DailyLogKind, text: String, taskID: UUID? = nil, taskTitle: String? = nil, taskNumber: Int? = nil, taskTags: [String] = [],
                images: [String] = [], imageText: [String: String] = [:], focus: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.taskNumber = taskNumber
        self.taskTags = taskTags
        self.images = images
        self.imageText = imageText
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, kind, text, taskID, taskTitle, taskNumber, taskTags, images, imageText, focus
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        kind = try values.decode(DailyLogKind.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        taskID = try values.decodeIfPresent(UUID.self, forKey: .taskID)
        taskTitle = try values.decodeIfPresent(String.self, forKey: .taskTitle)
        taskNumber = try values.decodeIfPresent(Int.self, forKey: .taskNumber)
        taskTags = try values.decodeIfPresent([String].self, forKey: .taskTags) ?? []
        images = try values.decodeIfPresent([String].self, forKey: .images) ?? []
        imageText = try values.decodeIfPresent([String: String].self, forKey: .imageText) ?? [:]
        focus = try values.decodeIfPresent(Bool.self, forKey: .focus) ?? false
    }

    /// 没有图片时不写入新字段，旧数据的 JSON 保持原样。
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(kind, forKey: .kind)
        try values.encode(text, forKey: .text)
        try values.encodeIfPresent(taskID, forKey: .taskID)
        try values.encodeIfPresent(taskTitle, forKey: .taskTitle)
        try values.encodeIfPresent(taskNumber, forKey: .taskNumber)
        if !taskTags.isEmpty { try values.encode(taskTags, forKey: .taskTags) }
        if !images.isEmpty { try values.encode(images, forKey: .images) }
        if !imageText.isEmpty { try values.encode(imageText, forKey: .imageText) }
        if focus { try values.encode(true, forKey: .focus) }
    }

    public var command: String { "/\(kind.rawValue) \(text)" }

    /// 搜索时用到的全部图片文字。
    public var recognizedText: String { images.compactMap { imageText[$0] }.filter { !$0.isEmpty }.joined(separator: "\n") }
}

public enum LogCommand: Equatable {
    case entry(DailyLogKind, String), help, summary
    /// `/link #1` 关联任务；`/link` 或 `/unlink`（nil）取消关联。
    case link(Int?)
    /// `/filter #1 #3` 只看这些任务相关的日志；`/filter`（空）清除筛选。
    case filter([Int])
    public static let commands = ["/note", "/done", "/block", "/plan", "/link", "/unlink", "/filter", "/summary", "/help"]

    public static func parse(_ input: String) throws -> LogCommand {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw LogInputError.empty }
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let command = String(parts[0]).lowercased()
        let body = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if let kind = DailyLogKind(rawValue: String(command.dropFirst())), command.hasPrefix("/") { return .entry(kind, body) }
        if command == "/help", body.isEmpty { return .help }
        if command == "/summary", body.isEmpty { return .summary }
        if command == "/unlink", body.isEmpty { return .link(nil) }
        if command == "/link" {
            if body.isEmpty { return .link(nil) }
            guard let number = taskNumber(body) else { throw LogInputError.badTaskReference(body) }
            return .link(number)
        }
        if command == "/filter" {
            let tokens = body.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).map(String.init)
            let numbers = try tokens.map { token -> Int in
                guard let number = taskNumber(token) else { throw LogInputError.badTaskReference(token) }
                return number
            }
            return .filter(numbers)
        }
        if command.hasPrefix("/"), !command.dropFirst().contains("/") {
            throw LogInputError.unknownCommand(command)
        }
        return .entry(.note, input)
    }

    /// 「#3」或「3」→ 3。
    public static func taskNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy(\.isASCII), let number = Int(digits), number > 0 else { return nil }
        return number
    }

    /// 日志正文开头的「#1」引用：`/done #1 完成了方法部分`、`#2 卡在配置`。
    public static func splitTaskReference(_ body: String) -> (number: Int?, rest: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return (nil, trimmed) }
        let token = trimmed.prefix { !$0.isWhitespace }
        guard let number = taskNumber(String(token)) else { return (nil, trimmed) }
        return (number, String(trimmed.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum LogInputError: LocalizedError {
    case empty, unknownCommand(String), missingTask, readOnly, badTaskReference(String), unknownTask(Int)
    public var errorDescription: String? {
        switch self {
        case .empty: return "请输入记录内容，或先关联一条任务。"
        case .unknownCommand(let command): return "未知命令 \(command)，输入 /help 查看用法。"
        case .missingTask: return "关联任务已删除，请重新选择任务或取消关联。"
        case .readOnly: return "当前数据只读，无法保存日志。"
        case .badTaskReference(let text): return "无法识别任务编号「\(text)」，请写成 #1。"
        case .unknownTask(let number): return "没有 #\(number) 号任务。编号显示在任务行左边，创建后不会变。"
        }
    }
}

public enum DailyReview {
    public static func render(_ entry: DayEntry) -> String {
        var sections: [String] = []
        for kind in [DailyLogKind.done, .block, .plan, .note] {
            let logs = entry.logs.filter { $0.kind == kind }
            var lines = logs.map { log -> String in
                let message = log.text.isEmpty && !log.images.isEmpty ? "[图片 \(log.images.count) 张]" : String(TaskText.rendered(log.text).characters)
                guard let task = log.taskTitle, !message.contains(task) else { return "- \(message)" }
                return "- \(message)（\(task)）"
            }
            if kind == .done {
                let logged = Set(logs.compactMap(\.taskID))
                lines += entry.todos.filter { $0.completed && !logged.contains($0.id) }
                    .map { "- " + String(TaskText.rendered($0.title).characters) }
            }
            if !lines.isEmpty || kind != .note { sections.append("## \(kind.title)\n" + lines.joined(separator: "\n")) }
        }
        return sections.joined(separator: "\n\n")
    }
}
