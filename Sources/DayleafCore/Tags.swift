import Foundation

/// 待办的标签：写成 `#标签`，纯数字的 `#3` 仍然表示任务编号，不算标签。
/// 标签不区分大小写；用 `/` 分层（`项目/子项`），查「项目」会包含它名下的子标签。
public enum TagText {
    public static let maxLength = 40

    /// 把用户输入整理成标签：去掉开头的 `#`、首尾空白和结尾标点，不允许空白、纯数字或空串。
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ",，.。;；:：!！?？、"))
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !text.isEmpty, text.count <= maxLength, !text.contains("#"),
              !text.contains(where: \.isWhitespace), !text.allSatisfy(\.isNumber) else { return nil }
        return text
    }

    /// 比较用的键：不区分大小写和音调。
    public static func key(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// 用空白或逗号分隔的一串标签（`#a #b`、`a,b`），去重并保持顺序。
    public static func parseList(_ text: String) -> [String] {
        merge([], text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).compactMap { normalize(String($0)) })
    }

    /// 在已有标签后追加新标签，已存在（不区分大小写）的不重复。
    public static func merge(_ existing: [String], _ added: [String]) -> [String] {
        var seen = Set(existing.map(key))
        var result = existing
        for tag in added where seen.insert(key(tag)).inserted { result.append(tag) }
        return result
    }

    /// `tag` 就是 `query`，或者是 `query` 名下的子标签（`项目/子项` 属于 `项目`）。
    public static func matches(_ tag: String, query: String) -> Bool {
        let tag = key(tag), query = key(query)
        return tag == query || tag.hasPrefix(query + "/")
    }

    /// 查询词是不是在找标签：以 `#` 开头，后面是合法标签。返回标签名。
    public static func searchTag(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#") ? normalize(trimmed) : nil
    }

    /// 从一行文字里取出 `#标签`（必须在开头或空白之后），返回去掉标签后的文字。
    /// Markdown 链接和网址里的 `#` 不算；整行只剩标签时原样保留，不生成空标题。
    public static func extract(from text: String) -> (title: String, tags: [String]) {
        var (work, links) = QuickAdd.mask(text)
        let tags = take(from: &work)
        guard !tags.isEmpty else { return (text, []) }
        let title = QuickAdd.unmask(work, links: links)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        links.removeAll()
        return title.isEmpty ? (text, []) : (title, tags)
    }

    /// 已经遮住链接的文字：取出所有标签并从原文里删掉。
    static func take(from work: inout String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\S)#([^\s#]+)"#) else { return [] }
        let source = work as NSString
        var tags: [String] = []
        var output = source
        for match in regex.matches(in: work, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let tag = normalize(source.substring(with: match.range(at: 1))) else { continue }
            tags.insert(tag, at: 0)
            output = output.replacingCharacters(in: match.range, with: " ") as NSString
        }
        work = output as String
        return merge([], tags)
    }
}

extension JournalStore {
    public struct TagSummary: Identifiable, Equatable {
        public var id: String { TagText.key(name) }
        public let name: String
        /// 带这个标签（含子标签）的待办数 / 其中未完成的。
        public let taskCount: Int
        public let openCount: Int
        /// 这些待办名下的笔记条数（不含专注记录）。
        public let noteCount: Int
        public let lastActivity: Date
    }

    /// 所有出现过的标签（不区分大小写合并）：待办上的，以及已删除待办的日志里留下的。
    /// `论文/方法` 也会让上级 `论文` 出现，数量按「含子标签」统计，和点进去看到的内容一致。有笔记的、最近有动静的排前面。
    public func allTags() -> [TagSummary] {
        var names: [String: String] = [:]
        var taskCounts: [String: (all: Int, open: Int)] = [:]
        var noteCounts: [String: (count: Int, latest: Date)] = [:]
        let live = liveTags()

        /// 一组标签涉及的所有层级（`a/b` 包含 `a` 和 `a/b`），每层只算一次。
        func levels(_ tags: [String]) -> [String] {
            var seen = Set<String>()
            var result: [String] = []
            for tag in tags {
                let parts = tag.split(separator: "/").map(String.init)
                for count in parts.indices {
                    let name = parts.prefix(count + 1).joined(separator: "/")
                    let key = TagText.key(name)
                    guard seen.insert(key).inserted else { continue }
                    names[key] = names[key] ?? name
                    result.append(key)
                }
            }
            return result
        }

        for item in tasks() {
            for key in levels(item.task.tags) {
                let previous = taskCounts[key] ?? (0, 0)
                taskCounts[key] = (previous.all + 1, previous.open + (item.task.completed ? 0 : 1))
            }
        }
        for day in days.values {
            for log in day.logs where !log.focus {
                for key in levels(effectiveTags(of: log, live: live)) {
                    let previous = noteCounts[key]
                    noteCounts[key] = ((previous?.count ?? 0) + 1, max(previous?.latest ?? .distantPast, log.createdAt))
                }
            }
        }
        return names.map { key, name in
            TagSummary(name: name, taskCount: taskCounts[key]?.all ?? 0, openCount: taskCounts[key]?.open ?? 0,
                       noteCount: noteCounts[key]?.count ?? 0, lastActivity: noteCounts[key]?.latest ?? .distantPast)
        }.sorted {
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func liveTags() -> [UUID: [String]] {
        Dictionary(tasks().map { ($0.id, $0.task.tags) }, uniquingKeysWith: { first, _ in first })
    }

    /// 日志的标签 = 关联待办的标签（待办还在用现在的，已删除用记录时的快照）+ 日志自己的标签。
    private func effectiveTags(of log: DailyLogEntry, live: [UUID: [String]]) -> [String] {
        let inherited: [String]
        if let id = log.taskID, let tags = live[id] { inherited = tags } else { inherited = log.taskTags }
        return log.tags.isEmpty ? inherited : TagText.merge(inherited, log.tags)
    }

    /// 带这个标签（或它的子标签）的待办，按清单顺序。
    public func tasks(taggedWith tag: String) -> [ScheduledTask] {
        tasks().filter { $0.task.tags.contains { TagText.matches($0, query: tag) } }.sorted(by: ScheduledTask.listOrder)
    }

    /// 一条日志现在带的标签：关联的待办还在就用它当前的标签（之后改标签会跟着变），已删除就用记录时的快照，再加上日志自己的标签。
    public func tags(of log: DailyLogEntry) -> [String] {
        effectiveTags(of: log, live: liveTags())
    }

    /// 这个标签（含子标签）名下所有待办的笔记，按时间从早到晚；不含专注计时记录。已删除待办的笔记靠记录时的标签快照仍然找得到。
    public func notes(forTag tag: String) -> [LoggedLog] {
        let live = liveTags()
        return allLogs(includeFocus: false).filter { item in effectiveTags(of: item.log, live: live).contains { TagText.matches($0, query: tag) } }
    }

    /// 同上，但包含专注计时的开始、结束记录。
    public func logs(forTag tag: String) -> [LoggedLog] {
        let live = liveTags()
        return allLogs(includeFocus: true).filter { item in effectiveTags(of: item.log, live: live).contains { TagText.matches($0, query: tag) } }
    }

    /// 整个替换一个待办的标签，作为一次可撤销的操作。
    public func setTags(_ id: UUID, _ tags: [String]) {
        guard !isReadOnly, let located = locate(id) else { return }
        let normalized = TagText.merge([], tags.compactMap(TagText.normalize))
        guard located.task.tags != normalized else { return }
        change(located.date, action: "标签") { entry in
            guard let index = entry.todos.firstIndex(where: { $0.id == id }) else { return }
            entry.todos[index].tags = normalized
        }
    }
}
