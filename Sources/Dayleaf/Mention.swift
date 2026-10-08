import AppKit
import SwiftUI
import DayleafCore

/// 输入框里正在写的 `@xxx`：`@` 必须在开头或空白之后，光标紧跟在词后面。
struct MentionToken: Equatable {
    /// 包含 `@` 的整段范围（UTF-16）。
    let range: NSRange
    /// `@` 后面写的字（拼音输入法的分隔符 `'` 已去掉）。
    let query: String

    static let maxQuery = 24

    static func find(in text: String, caret: Int) -> MentionToken? {
        let ns = text as NSString
        guard caret >= 1, caret <= ns.length else { return nil }
        var index = caret
        while index > 0 {
            let unit = ns.character(at: index - 1)
            if unit == 0x40 || unit == 0xFF20 {
                let start = index - 1
                if start > 0, !isSpace(ns.character(at: start - 1)) { return nil }
                let raw = ns.substring(with: NSRange(location: index, length: caret - index))
                guard raw.count <= maxQuery else { return nil }
                return MentionToken(range: NSRange(location: start, length: caret - start),
                                    query: raw.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: ""))
            }
            if isSpace(unit) { return nil }
            index -= 1
        }
        return nil
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

/// `@` 补全的状态：输入框（`TaskInput`）负责发现 `@xxx` 和处理 ↑ ↓ 回车 Tab Esc，候选由所在的界面按上下文提供。
@MainActor
final class MentionState: ObservableObject {
    static let limit = 6

    @Published private(set) var token: MentionToken?
    @Published private(set) var results: [ScheduledTask] = []
    @Published var selection = 0

    /// 按查询词给出候选（调用方带上正在写的标签等上下文）。
    var provider: (String) -> [ScheduledTask] = { _ in [] }
    /// 选中一个待办之后。`@xxx` 已经从输入框里删掉了。
    var onPick: (UUID) -> Void = { _ in }
    /// 输入框注册的「确认当前选择」，列表里点一下也走这里。
    var acceptAction: (() -> Bool)?
    /// 按 Esc 关掉的那个 `@`（位置）：在它被删掉或重新输入之前不再弹出。
    private var dismissedAt: Int?

    var isActive: Bool { token != nil && !results.isEmpty }

    func update(_ new: MentionToken?) {
        guard let new else {
            dismissedAt = nil
            clear()
            return
        }
        if new.range.location == dismissedAt { clear(); return }
        guard new != token else { return }
        let changed = new.query != token?.query || new.range.location != token?.range.location
        token = new
        results = Array(provider(new.query).prefix(Self.limit))
        if changed { selection = 0 }
    }

    func move(_ delta: Int) {
        guard isActive else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func dismiss() {
        dismissedAt = token?.range.location
        clear()
    }

    /// 取走当前选中的候选，同时关闭列表。
    func take() -> (token: MentionToken, id: UUID)? {
        guard isActive, let token, results.indices.contains(selection) else { return nil }
        let id = results[selection].id
        dismissedAt = nil
        clear()
        return (token, id)
    }

    func choose(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selection = index
        _ = acceptAction?()
    }

    private func clear() {
        if token != nil { token = nil }
        if !results.isEmpty { results = [] }
    }
}

/// 输入框下面的 `@` 候选列表。
struct MentionList: View {
    @ObservedObject var state: MentionState
    @ObservedObject var store: JournalStore
    /// 正在写的标签等：带这些标签的待办会排前面，并标出来。
    var contextTags: [String] = []

    var body: some View {
        if state.isActive {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(state.results.enumerated()), id: \.element.id) { index, item in row(item, index: index) }
                Text("↑ ↓ 选择 · 回车 / Tab 关联 · Esc 取消").font(.system(size: UIScale.pt(10))).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .padding(.vertical, 3)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            .accessibilityElement(children: .contain).accessibilityLabel("关联待办候选")
        }
    }

    private func row(_ item: ScheduledTask, index: Int) -> some View {
        let isFocus = item.id == store.focusTaskID
        let isPinned = item.id == store.pinnedTask?.id
        let shared = item.task.tags.filter { tag in contextTags.contains { TagText.matches(tag, query: $0) || TagText.matches($0, query: tag) } }
        return HStack(spacing: 6) {
            Text(item.task.number.map { "#\($0)" } ?? "").font(.system(size: UIScale.pt(11), design: .monospaced))
                .foregroundStyle(Palette.muted).frame(width: 34, alignment: .leading)
            Text(String(TaskText.rendered(item.task.title, alias: item.task.calendarName).characters))
                .font(.system(size: UIScale.pt(13))).lineLimit(1)
            if isFocus { Image(systemName: "timer").foregroundStyle(Palette.success).font(.system(size: UIScale.pt(10))) }
            if isPinned { Image(systemName: "pin.fill").foregroundStyle(Palette.accent).font(.system(size: UIScale.pt(10))) }
            Spacer(minLength: 4)
            ForEach(Array((shared.isEmpty ? Array(item.task.tags.prefix(2)) : shared).prefix(2)), id: \.self) { tag in
                Text("#" + tag).font(.system(size: UIScale.pt(10))).lineLimit(1)
                    .foregroundStyle(shared.contains(tag) ? Palette.accent : Palette.muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index == state.selection ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in state.choose(index) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((item.task.number.map { "#\($0) " } ?? "") + item.task.title)
        .accessibilityAddTraits(.isButton)
    }
}
