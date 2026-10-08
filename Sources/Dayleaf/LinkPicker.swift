import AppKit
import SwiftUI
import DayleafCore

/// 带搜索的「关联待办」选择面板：待办多的时候不再是一长串菜单。
/// 输入标题、编号（`3` 或 `#3`）或 `#标签` 筛选；↑ ↓ 选择，回车确认；专注中的、最近关联过的排在最前。
struct LinkPickerView: View {
    @ObservedObject var store: JournalStore
    /// 当前已经关联的待办（打勾显示）。
    var current: UUID?
    /// 显示「不关联任务」。
    var allowsNone = true
    /// 正在写的标签等：带这些标签的待办排在前面。
    var contextTags: [String] = []
    let pick: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showCompleted = false
    @State private var selection = 0
    @FocusState private var searching: Bool

    private var results: [ScheduledTask] { store.linkCandidates(query: query, includeCompleted: showCompleted, contextTags: contextTags) }

    var body: some View {
        let list = results
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索标题、编号、#标签或拼音", text: $query).textFieldStyle(.plain).focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("清除搜索词")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
            if allowsNone {
                Button { pick(nil); dismiss() } label: {
                    Label("不关联任务", systemImage: current == nil ? "checkmark" : "xmark.circle").font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Palette.muted)
            }
            if list.isEmpty {
                Text(query.isEmpty ? "没有未完成的待办" : "没有匹配「\(query)」的待办").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                row(item, highlighted: index == selection).id(item.id)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(list.count) * 46 + 4, 300))
                    .onChange(of: selection) { index in if list.indices.contains(index) { proxy.scrollTo(list[index].id) } }
                }
            }
            HStack {
                Toggle("显示已完成", isOn: $showCompleted).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Text("↑ ↓ 选择 · 回车确认").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(width: 380)
        .background(SearchKeyCatcher(move: { amount in
            let count = results.count
            guard count > 0 else { return }
            selection = min(max(selection + amount, 0), count - 1)
        }, activate: {
            let items = results
            guard items.indices.contains(selection) else { return }
            pick(items[selection].id)
            dismiss()
        }))
        .onAppear { searching = true }
        .onChange(of: query) { _ in selection = 0 }
        .onChange(of: showCompleted) { _ in selection = 0 }
    }

    private func row(_ item: ScheduledTask, highlighted: Bool) -> some View {
        Button { pick(item.id); dismiss() } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(item.task.number.map { "#\($0)" } ?? "").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted).frame(width: 34, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(String(TaskText.rendered(item.task.title, alias: item.task.calendarName).characters))
                            .font(.system(size: 13)).lineLimit(1)
                        if item.id == store.focusTaskID { Image(systemName: "timer").foregroundStyle(Palette.success).font(.system(size: 10)) }
                        if item.id == store.pinnedTask?.id { Image(systemName: "pin.fill").foregroundStyle(Palette.accent).font(.system(size: 10)) }
                        if item.task.completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success).font(.system(size: 10)) }
                    }
                    HStack(spacing: 6) {
                        if let due = item.task.dueDate { Text("截止 " + due.relativeLabel) }
                        ForEach(item.task.tags, id: \.self) { Text("#" + $0).foregroundStyle(Palette.accent) }
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.id == current { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((item.task.number.map { "#\($0) " } ?? "") + item.task.title)
    }
}

/// 一个会弹出 `LinkPickerView` 的按钮外壳。
struct LinkPickerButton<Label: View>: View {
    @ObservedObject var store: JournalStore
    var current: UUID?
    var allowsNone = true
    var contextTags: [String] = []
    let pick: (UUID?) -> Void
    @ViewBuilder let label: () -> Label
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                LinkPickerView(store: store, current: current, allowsNone: allowsNone, contextTags: contextTags, pick: pick)
            }
    }
}

/// 一条要写的日志会关联到哪个待办，以及怎么改：明确选的 > 专注中的 > 固定关联的；也可以明确「不关联」。
/// 在输入框里写 `@` 加几个字也能选（见 `MentionList`）。选定的待办可以一键「固定」：之后的日志默认都记到它名下，不计时。
struct LogLinkBar: View {
    @ObservedObject var store: JournalStore
    @Binding var link: UUID?
    @Binding var unlinked: Bool
    var contextTags: [String] = []
    var size: CGFloat = 11

    private var explicit: ScheduledTask? { link.flatMap(store.locate) }

    private func choose(_ id: UUID?) {
        if let id { link = id; unlinked = false } else { link = nil; unlinked = store.defaultLinkTask != nil }
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            if let task = explicit {
                pill("link", FocusHint.label(task), tint: Palette.accent)
                small("xmark", "取消这次的关联") { link = nil }
                let pinned = store.pinnedTask?.id == task.id
                small(pinned ? "pin.fill" : "pin", pinned ? "取消固定" : "固定为当前待办：之后的日志默认都记到它名下（不计时），再点一次取消",
                      tint: pinned ? Palette.accent : Palette.muted) { store.pinTask(pinned ? nil : task.id) }
            } else if unlinked {
                pill("link.badge.plus", "这条不关联待办", tint: Palette.muted)
                small("arrow.uturn.backward", "恢复自动关联") { unlinked = false }
            } else if let focus = store.focusTask {
                pill("timer", "专注中，自动关联 " + FocusHint.label(focus), tint: Palette.success)
                small("xmark", "这条不关联") { unlinked = true }
            } else if let pinned = store.pinnedTask {
                pill("pin.fill", "固定关联 " + FocusHint.label(pinned), tint: Palette.accent)
                small("pin.slash", "取消固定") { store.pinTask(nil) }
                small("xmark", "这条不关联") { unlinked = true }
            }
            LinkPickerButton(store: store, current: explicit?.id, contextTags: contextTags, pick: choose) {
                if explicit == nil, !unlinked, store.defaultLinkTask == nil {
                    Label("@ 关联待办", systemImage: "link").font(.system(size: size)).padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [3])))
                        .foregroundStyle(Palette.muted)
                } else {
                    Text("更换").font(.system(size: size)).foregroundStyle(Palette.muted).padding(.vertical, 4)
                }
            }
            .help("选择要关联的待办；也可以在输入框里写 @ 加标题、编号或拼音")
            .accessibilityLabel("选择关联的待办")
        }
        .disabled(store.isReadOnly)
    }

    private func pill(_ symbol: String, _ text: String, tint: Color) -> some View {
        Label(text, systemImage: symbol).font(.system(size: UIScale.pt(size))).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    private func small(_ symbol: String, _ help: String, tint: Color = Palette.muted, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: UIScale.pt(size))).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(tint).help(help).accessibilityLabel(help)
    }
}

/// 多选标签（快速日志、笔记输入框用）：现有标签是圆角矩形，选中的高亮，点一下切换；也能直接建新标签（会存进标签注册表）。
struct TagSelectionBar: View {
    @ObservedObject var store: JournalStore
    @Binding var selection: [String]
    var maxVisible = 12
    /// 「新标签」输入框里的字；传入时由调用方保存（窗口关掉也不丢），不传就只在这个视图里。
    var draftBinding: Binding<String>?
    @State private var creating = false
    @State private var localDraft = ""
    private var draft: Binding<String> { draftBinding ?? $localDraft }
    @State private var message: String?
    @FocusState private var typing: Bool

    private var choices: [String] {
        let top = store.allTags().prefix(maxVisible).map(\.name)
        return TagText.merge(selection, Array(top))
    }

    private func isSelected(_ tag: String) -> Bool { selection.contains { TagText.key($0) == TagText.key(tag) } }

    private func toggle(_ tag: String) {
        if isSelected(tag) { selection.removeAll { TagText.key($0) == TagText.key(tag) } } else { selection.append(tag) }
    }

    private func create() {
        let tags = TagText.parseList(draft.wrappedValue)
        guard !tags.isEmpty else { message = draft.wrappedValue.isEmpty ? nil : "标签不能含空格，也不能是纯数字"; return }
        for tag in tags {
            let name = store.createTag(tag) ?? tag
            if !isSelected(name) { selection.append(name) }
        }
        draft.wrappedValue = ""
        message = nil
        creating = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 5) {
                Image(systemName: "tag").font(.system(size: 11)).foregroundStyle(Palette.muted).frame(height: 24)
                ForEach(choices, id: \.self) { tag in
                    Button { toggle(tag) } label: { TagChip(name: tag, highlighted: isSelected(tag), size: 11) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("#\(tag)").accessibilityValue(isSelected(tag) ? "已选中" : "未选中")
                }
                Button { creating.toggle(); if creating { typing = true } } label: {
                    Label("新标签", systemImage: "plus").font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [3])))
                }.buttonStyle(.plain).foregroundStyle(Palette.muted)
            }
            if creating || !draft.wrappedValue.isEmpty {
                HStack(spacing: 6) {
                    TextField("新标签名，回车创建（可用 / 分层）", text: draft).textFieldStyle(.plain).focused($typing).onSubmit(create)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                    if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }
}

enum LogClipboard {
    /// 复制日志文字（只有文字，图片不算）。返回复制了几条；没有可复制的文字返回 0。
    @MainActor
    @discardableResult
    static func copy(store: JournalStore, ids: Set<UUID>) -> Int {
        guard let text = store.copyText(forLogs: ids) else { return 0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return store.allLogs(includeFocus: true).filter { ids.contains($0.log.id) && $0.log.copyText != nil }.count
    }
}
