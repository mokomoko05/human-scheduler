import AppKit
import SwiftUI
import DayleafCore

/// 笔记视图：每个 TODO 是一个主题，它名下（/link、/done #N 等）的日志按日期汇成笔记；每个标签也是一个主题，汇总带这个标签的所有待办的笔记。专注计时记录不在这里显示。
struct NotesView: View {
    @ObservedObject var store: JournalStore
    let initialSelection: UUID?
    let initialTag: String?
    let close: () -> Void
    let reveal: (UUID) -> Void
    let openDay: (Date) -> Void
    /// 停在哪里（选中的任务 / 标签、搜索词、视图方式）：存进偏好，关掉再开回到原处。
    @ObservedObject var nav: NotesNavigation
    @State private var creatingTag = false
    @State private var newTagName = ""
    @State private var newTagMessage: String?
    @State private var tagFocused = false
    @State private var editingNoteID: UUID?
    @State private var noteEditText = ""
    @State private var noteEditFocused = false
    @State private var previewing: ImagePreviewItem?
    @State private var focused = false
    @State private var error: String?

    private var selection: UUID? { get { nav.selection } nonmutating set { nav.selection = newValue } }
    private var tagSelection: String? { get { nav.tagSelection } nonmutating set { nav.tagSelection = newValue } }
    private var query: String { nav.query }
    private var chapterView: Bool { nav.chapterView }

    // 草稿按「当前任务 / 当前标签」分开存在 nav 里：切换、关窗口、失焦都不丢。
    private func taskDraftKey(_ id: UUID) -> String { NotesNavigation.draftKey(task: id) }
    private func tagDraftKey(_ tag: String) -> String { NotesNavigation.draftKey(tag: tag) }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { nav.draft(key).text }, set: { value in nav.updateDraft(key) { $0.text = value } })
    }
    private func images(_ key: String) -> [String] { nav.draft(key).images }
    private func addImages(_ names: [String], to key: String) { nav.updateDraft(key) { $0.images += names } }
    private func removeImage(_ name: String, from key: String) { nav.updateDraft(key) { $0.images.removeAll { $0 == name } } }

    /// 明确指定了任务或标签（比如点了待办上的标签）就跳过去；否则保持 `nav` 里上次停留的位置。
    init(store: JournalStore, initialSelection: UUID? = nil, initialTag: String? = nil, nav: NotesNavigation? = nil,
         close: @escaping () -> Void = {}, reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        self.store = store
        self.initialSelection = initialSelection
        self.initialTag = initialTag
        self.close = close
        self.reveal = reveal
        self.openDay = openDay
        let nav = nav ?? NotesNavigation()
        self.nav = nav
        if let initialTag { nav.open(tag: initialTag) } else if let initialSelection { nav.open(task: initialSelection) }
        else if nav.selection == nil, nav.tagSelection == nil { nav.validate(in: store) }
    }

    /// 搜索词去掉开头的 `#`；以 `#` 开头（且不是 `#3` 这样的编号）表示只找标签。
    private var tagQuery: String? { TagText.searchTag(query) }
    private var plainQuery: String { query.hasPrefix("#") ? String(query.drop(while: { $0 == "#" })) : query }

    private var topics: [JournalStore.NoteTopic] {
        let all = store.noteTopics()
        guard !query.isEmpty else { return all }
        if let tag = tagQuery { return all.filter { $0.tags.contains { TagText.matches($0, query: tag) } } }
        return all.filter {
            $0.title.localizedStandardContains(query) || ($0.number.map { "#\($0)" } ?? "").contains(query)
                || $0.tags.contains { $0.localizedStandardContains(plainQuery) }
        }
    }

    private var tagRows: [JournalStore.TagSummary] {
        let all = store.allTags()
        guard !plainQuery.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(plainQuery) }
    }

    private var current: JournalStore.NoteTopic? {
        let all = store.noteTopics()
        return all.first { $0.id == selection } ?? (selection == nil ? nil : nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            detail.frame(maxWidth: .infinity)
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .sheet(item: $previewing) { ImagePreviewSheet(store: store, item: $0) }
        .onAppear { nav.validate(in: store) }
    }

    // MARK: - 左侧：有笔记的任务

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "note.text").foregroundStyle(Palette.accent)
                Text("笔记").font(.system(size: 16, weight: .semibold))
                Spacer()
                let key = HotKeyStore.binding(for: .notes).label
                Text("\(key) 关闭").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .help("\(key) 或 Esc 关闭笔记；窗口没有标题栏按钮，拖动空白处可移动")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索任务或标签（#标签）", text: $nav.query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
            let list = topics
            let tagList = tagRows
            if list.isEmpty && tagList.isEmpty && !query.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "note.text").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.muted.opacity(0.6))
                    Text("没有匹配的任务或标签").font(.system(size: 13, weight: .medium))
                    if query.isEmpty {
                        Text("在日志输入框写 /link #1 把日志记到某个任务名下，或直接写 /done #1 内容。笔记按任务汇总在这里；给待办打上标签，还能按标签汇总。")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        tagSectionHeader
                        if tagList.isEmpty {
                            Text("还没有标签。点右上角 + 新建一个笔记本，或给待办打上 #标签。")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.bottom, 4)
                        }
                        ForEach(tagList) { tagRow($0) }
                        if !list.isEmpty {
                            sectionTitle("任务")
                            ForEach(list) { topic in topicRow(topic) }
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            .padding(.horizontal, 10).padding(.top, 6)
    }

    /// 「标签」小标题，右边的 + 创建一个新标签（笔记本），可以先建空的、以后再写。
    private var tagSectionHeader: some View {
        HStack(spacing: 4) {
            sectionTitle("标签（笔记本）")
            Spacer(minLength: 0)
            Button { newTagName = ""; newTagMessage = nil; creatingTag = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Palette.accent).padding(.top, 6)
            .help("新建标签：可以先建一个空的笔记本，以后再往里写").accessibilityLabel("新建标签")
            .disabled(store.isReadOnly)
            .popover(isPresented: $creatingTag, arrowEdge: .trailing) { newTagPopover }
        }
    }

    private var newTagPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新建标签").font(.headline)
            TextField("标签名，例如 读书笔记 或 项目/子项", text: $newTagName).textFieldStyle(.roundedBorder).onSubmit(createTag)
            if let newTagMessage { Text(newTagMessage).font(.caption).foregroundStyle(.orange) }
            Text("标签不含空格；用 / 分层，`论文/方法` 属于 `论文`。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { creatingTag = false }.keyboardShortcut(.cancelAction)
                Button("创建") { createTag() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(16).frame(width: 300)
    }

    private func createTag() {
        guard let name = store.createTag(newTagName) else {
            newTagMessage = "标签不能为空、含空格，或是纯数字（#3 表示任务编号）"
            return
        }
        creatingTag = false
        select(tag: name)
    }

    private func select(task id: UUID) {
        selection = id
        tagSelection = nil
        error = nil
    }

    private func select(tag: String) {
        tagSelection = tag
        selection = nil
        error = nil
    }

    private func tagRow(_ summary: JournalStore.TagSummary) -> some View {
        let chosen = tagSelection.map { TagText.key($0) == TagText.key(summary.name) } == true
        return Button { select(tag: summary.name) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("#" + summary.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent).lineLimit(1)
                HStack(spacing: 8) {
                    if summary.taskCount == 0 && summary.noteCount == 0 {
                        Text("空标签")
                    } else {
                        Text("\(summary.taskCount) 个待办").monospacedDigit()
                        Text("\(summary.noteCount) 条笔记").monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    if summary.lastActivity > .distantPast { Text(summary.lastActivity.relativeLabel) }
                }
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chosen ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("标签 \(summary.name)，\(summary.taskCount) 个待办，\(summary.noteCount) 条笔记")
        .contextMenu {
            if summary.taskCount == 0 && summary.noteCount == 0 {
                Button("删除这个空标签", role: .destructive) {
                    if store.removeEmptyTag(summary.name), tagSelection.map({ TagText.key($0) == summary.id }) == true { tagSelection = nil }
                }
            } else {
                Text("正在使用的标签不能删除")
            }
        }
    }

    private func topicRow(_ topic: JournalStore.NoteTopic) -> some View {
        Button { select(task: topic.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let number = topic.number {
                        Text("#\(number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                    Text(topic.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if topic.completed { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.success) }
                }
                HStack(spacing: 8) {
                    Text("\(topic.count) 条").monospacedDigit()
                    if topic.imageCount > 0 { Label("\(topic.imageCount)", systemImage: "photo") }
                    if topic.deleted { Text("任务已删除") }
                    Spacer(minLength: 4)
                    Text(topic.lastActivity.relativeLabel)
                }
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection == topic.id ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(topic.number.map { "#\($0) " } ?? "")\(topic.title)，\(topic.count) 条笔记")
    }

    // MARK: - 右侧：这个任务名下的笔记

    @ViewBuilder
    private var detail: some View {
        if let tag = tagSelection {
            tagDetail(tag)
        } else if let id = selection, let topic = store.noteTopics().first(where: { $0.id == id }) {
            let notes = store.notes(for: id)
            VStack(spacing: 0) {
                header(topic, notes: notes)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Dictionary(grouping: notes, by: \.key).sorted { $0.key < $1.key }, id: \.key) { group in
                                dayHeader(group.key, date: group.value[0].date)
                                ForEach(group.value) { item in noteRow(item) }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }.padding(20)
                    }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: notes.count) { _ in withAnimation(Motion.quick) { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: selection) { _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                Divider()
                composer(topic)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.book.closed").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.muted.opacity(0.6))
                Text("从左侧选择一个任务或标签").font(.system(size: 14, weight: .medium))
                Text("它名下的所有日志会按日期汇总成笔记，包括图片；标签会汇总带它的所有待办的笔记。").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ topic: JournalStore.NoteTopic, notes: [JournalStore.LoggedLog]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let number = topic.number {
                        Text("#\(number)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent)
                    }
                    Text(topic.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if topic.completed { Label("已完成", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.success) }
                    if topic.deleted { Label("任务已删除", systemImage: "trash").foregroundStyle(Palette.deadline) }
                    if let due = topic.dueDate { Label("截止 \(due.relativeLabel)", systemImage: "clock") }
                    if topic.focusSeconds >= 1 { Label("已专注 \(FocusSession.brief(topic.focusSeconds))", systemImage: "hourglass") }
                    Text("\(topic.count) 条笔记")
                }
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                if !topic.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(topic.tags, id: \.self) { tag in
                            Button { select(tag: tag) } label: { TagChip(name: tag, size: 11) }
                                .buttonStyle(.plain).help("查看 #\(tag) 名下所有待办的笔记")
                        }
                    }
                }
            }
            Spacer()
            if !topic.deleted {
                Button { close(); reveal(topic.id) } label: { Label("在清单中显示", systemImage: "list.bullet") }
                    .help("关闭笔记，回到清单并选中这个任务")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.markdown(topic, notes: notes), forType: .string)
                error = "已复制为 Markdown"
            } label: { Label("复制为 Markdown", systemImage: "doc.on.doc") }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func dayHeader(_ key: String, date: Date) -> some View {
        Button { close(); openDay(date) } label: {
            HStack(spacing: 6) {
                Text(date.relativeLabel).font(.system(size: 12, weight: .semibold))
                Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
        .buttonStyle(.plain).foregroundStyle(Palette.accent)
        .padding(.top, 14).padding(.bottom, 4)
        .help("跳到这一天的日志")
    }

    private func noteRow(_ item: JournalStore.LoggedLog, showTask: Bool = false, showDate: Bool = false) -> some View {
        let log = item.log
        return HStack(alignment: .top, spacing: 10) {
            Text((showDate ? String(item.key.dropFirst(5)) + " " : "") + Self.time(log.createdAt)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).padding(.top, 2)
            Text(log.kind.label).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(kindColor(log.kind).opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(kindColor(log.kind)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                if showTask, let label = Self.sourceLabel(log) {
                    Button { if let id = log.taskID, store.noteTopics().contains(where: { $0.id == id }) { select(task: id) } } label: {
                        Text(label).font(.system(size: 11)).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Palette.soft, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent).help("查看这个待办的全部笔记")
                }
                if editingNoteID == log.id {
                    VStack(alignment: .leading, spacing: 4) {
                        TaskInput(text: $noteEditText, focused: $noteEditFocused, fontSize: 13,
                                  submit: { saveNoteEdit(item) }, cancel: cancelNoteEdit, minHeight: 24, maxLines: 12)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.accent.opacity(0.6)))
                            .onAppear { noteEditFocused = true }
                        Text("回车保存 · ⇧回车换行 · Esc 取消 · 清空后保存会删除这条（可撤销）").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                } else if !log.text.isEmpty {
                    Text(TaskText.rendered(log.text)).font(.system(size: 13)).textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in SafariLinks.open(url); return .handled })
                }
                if !log.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(log.images.enumerated()), id: \.element) { index, name in
                                Button { previewing = ImagePreviewItem(names: log.images, index: index) } label: {
                                    ImageFit(url: store.imageURL(name), maxWidth: 440, maxHeight: 280)
                                }.buttonStyle(.plain).help("点击查看大图")
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                noteAction("doc.on.doc", log.copyText == nil ? "这条只有图片，没有文字可复制" : "复制这条的文字（不含图片）") { copy(log) }
                    .disabled(log.copyText == nil)
                if !store.isReadOnly {
                    noteAction("pencil", "编辑这条笔记") { beginNoteEdit(log) }
                    LinkPickerButton(store: store, current: log.taskID, pick: { store.setLogTask($0, forLog: log.id, on: item.date) }) {
                        Image(systemName: "link").font(.system(size: 11)).frame(width: 24, height: 22).contentShape(Rectangle())
                    }
                    .foregroundStyle(Palette.muted).help("更换这条笔记关联的待办（章节）").accessibilityLabel("更换关联的待办")
                    noteAction("trash", "删除这条笔记 · ⌘Z 撤销", destructive: true) { deleteNote(item) }
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 5)
    }

    private func noteAction(_ symbol: String, _ help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(destructive ? Palette.deadline : Palette.muted)
        .help(help).accessibilityLabel(help)
    }

    private func beginNoteEdit(_ log: DailyLogEntry) {
        editingNoteID = log.id
        noteEditText = log.text
        noteEditFocused = true
    }

    private func cancelNoteEdit() {
        editingNoteID = nil
        noteEditFocused = false
    }

    private func saveNoteEdit(_ item: JournalStore.LoggedLog) {
        guard editingNoteID == item.log.id else { return }
        editingNoteID = nil
        store.updateLog(item.log.id, text: noteEditText, on: item.date)
    }

    private func deleteNote(_ item: JournalStore.LoggedLog) {
        if editingNoteID == item.log.id { editingNoteID = nil }
        store.deleteLog(item.log.id, on: item.date)
        error = "已删除这条笔记，⌘Z 可撤销"
    }

    private func copy(_ log: DailyLogEntry) {
        error = LogClipboard.copy(store: store, ids: [log.id]) > 0 ? "已复制这条笔记的文字" : "这条只有图片，没有文字可复制"
    }

    // MARK: - 右侧：一个标签名下所有待办的笔记

    private static func sourceLabel(_ log: DailyLogEntry) -> String? {
        guard let title = log.taskTitle else { return nil }
        return (log.taskNumber.map { "#\($0) " } ?? "") + title
    }

    private func tagDetail(_ tag: String) -> some View {
        let tasks = store.tasks(taggedWith: tag)
        let notes = store.notes(forTag: tag)
        return VStack(spacing: 0) {
            tagHeader(tag, tasks: tasks, notes: notes)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if notes.isEmpty && tasks.isEmpty {
                            Text("这个笔记本还是空的。在下面直接写一条，或给待办打上 #\(tag)。")
                                .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 12)
                        }
                        if chapterView { chapterList(tag) } else { dateList(notes) }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(20)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: tagSelection) { _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: notes.count) { _ in withAnimation(Motion.quick) { proxy.scrollTo("end", anchor: .bottom) } }
            }
            Divider()
            tagComposer(tag)
        }
    }

    /// 按待办（章节）：标签是笔记本，每个待办是里面的一章。
    @ViewBuilder
    private func chapterList(_ tag: String) -> some View {
        ForEach(store.chapters(forTag: tag)) { chapter in
            chapterHeader(chapter)
            if chapter.notes.isEmpty {
                Text("还没有笔记").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.leading, 4).padding(.bottom, 6)
            }
            ForEach(chapter.notes) { item in noteRow(item, showDate: true) }
        }
    }

    private func chapterHeader(_ chapter: NotebookChapter) -> some View {
        let canOpen = chapter.taskID.map { id in store.noteTopics().contains { $0.id == id } } ?? false
        return Button { if let id = chapter.taskID, canOpen { select(task: id) } } label: {
            HStack(spacing: 6) {
                Image(systemName: chapter.taskID == nil ? "square.and.pencil" : (chapter.completed ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(chapter.completed ? Palette.success : Palette.muted).font(.system(size: 12))
                if let number = chapter.number {
                    Text("#\(number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                }
                Text(chapter.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(chapter.notes.count) 条").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
        .buttonStyle(.plain).foregroundStyle(Palette.accent)
        .padding(.top, 14).padding(.bottom, 4)
        .help(canOpen ? "只看这个待办的全部笔记" : "")
    }

    private func dateList(_ notes: [JournalStore.LoggedLog]) -> some View {
        ForEach(Dictionary(grouping: notes, by: \.key).sorted { $0.key < $1.key }, id: \.key) { group in
            dayHeader(group.key, date: group.value[0].date)
            ForEach(group.value) { item in noteRow(item, showTask: true) }
        }
    }

    private func tagHeader(_ tag: String, tasks: [ScheduledTask], notes: [JournalStore.LoggedLog]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("#" + tag).font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.accent).lineLimit(2)
                    Text("\(tasks.count) 个待办（\(tasks.filter { !$0.task.completed }.count) 个未完成） · \(notes.count) 条笔记")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Picker("", selection: $nav.chapterView) {
                    Text("按待办").tag(true)
                    Text("按日期").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.markdown(tag: tag, tasks: tasks, notes: notes), forType: .string)
                    error = "已复制为 Markdown"
                } label: { Label("复制为 Markdown", systemImage: "doc.on.doc") }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// 标签页底部：直接往这个笔记本里写，不需要关联待办；也可以顺手选一个待办作为它的章节。
    private func tagComposer(_ tag: String) -> some View {
        let key = tagDraftKey(tag)
        let pending = images(key)
        let link = nav.draft(key).link
        let text = nav.draft(key).text
        return VStack(alignment: .leading, spacing: 6) {
            if !pending.isEmpty {
                PendingImagesStrip(store: store, names: pending,
                                   remove: { name in removeImage(name, from: key) },
                                   preview: { previewing = ImagePreviewItem(names: pending, index: $0) })
            }
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(Palette.accent)
                TaskInput(text: textBinding(key), focused: $tagFocused,
                          placeholder: "写进 #\(tag)，回车保存，⌘V 粘贴图片",
                          fontSize: 13, submit: { submitTag(tag) }, onPasteImages: { datas in
                    addImages(ImageTools.save(datas, in: store), to: key)
                    tagFocused = true
                }, minHeight: 24, maxLines: 10).disabled(store.isReadOnly)
                LinkPickerButton(store: store, current: link, pick: { picked in nav.updateDraft(key) { $0.link = picked } }) {
                    Label(link.flatMap { store.locate($0) }.map { FocusHint.label($0) } ?? "关联待办（可选）", systemImage: "link")
                        .font(.system(size: 11)).lineLimit(1).frame(maxWidth: 190)
                        .foregroundStyle(link == nil ? Palette.muted : Palette.accent)
                }.fixedSize().disabled(store.isReadOnly).help("把这条记在某个待办（章节）名下；不选就是直接记在笔记本里")
                Button { submitTag(tag) } label: { Image(systemName: "arrow.turn.down.left") }
                    .buttonStyle(HitAreaButtonStyle())
                    .disabled(store.isReadOnly || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            if let focus = store.focusTask, link == nil {
                Text("专注中：不选待办时，这条会关联到 \(FocusHint.label(focus))").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(error.hasPrefix("已") ? Palette.success : Palette.deadline)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func submitTag(_ tag: String) {
        let key = tagDraftKey(tag)
        let draft = nav.draft(key)
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draft.images.isEmpty else { return }
        do {
            let command = try store.quickLog(text, images: draft.images, taskID: draft.link, tags: [tag], on: Date())
            guard case .entry = command else { error = "这里只能写笔记，不支持 \(text) 这类命令。"; return }
            nav.clearDraft(key)
            error = nil
            tagFocused = true
            ImageIndexer.run(store: store)
        } catch { self.error = error.localizedDescription }
    }

    /// 标签的笔记导出为 Markdown：先列出待办，再按日期分组，每条标明来自哪个待办。
    static func markdown(tag: String, tasks: [ScheduledTask], notes: [JournalStore.LoggedLog]) -> String {
        var lines = ["# #\(tag)", ""]
        for item in tasks {
            lines.append("- [\(item.task.completed ? "x" : " ")] \(item.task.number.map { "#\($0) " } ?? "")\(String(TaskText.rendered(item.task.title).characters))")
        }
        if !tasks.isEmpty { lines.append("") }
        for group in Dictionary(grouping: notes, by: \.key).sorted(by: { $0.key < $1.key }) {
            lines.append("## \(group.key)")
            for item in group.value {
                let log = item.log
                let source = sourceLabel(log).map { "（\($0)）" } ?? ""
                var line = "- \(time(log.createdAt)) [\(log.kind.label)] \(String(TaskText.rendered(log.text).characters))\(source)"
                for name in log.images { line += "\n  ![](Images/\(name))" }
                lines.append(line)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func composer(_ topic: JournalStore.NoteTopic) -> some View {
        let key = taskDraftKey(topic.id)
        let pending = images(key)
        let text = nav.draft(key).text
        return VStack(alignment: .leading, spacing: 6) {
            if !pending.isEmpty {
                PendingImagesStrip(store: store, names: pending,
                                   remove: { name in removeImage(name, from: key) },
                                   preview: { previewing = ImagePreviewItem(names: pending, index: $0) })
            }
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(Palette.accent)
                TaskInput(text: textBinding(key), focused: $focused,
                          placeholder: topic.deleted ? "任务已删除，无法追加笔记" : "给 \(topic.number.map { "#\($0)" } ?? "这个任务") 追加笔记，回车保存，⌘V 粘贴图片",
                          fontSize: 13, submit: { submit(topic) }, onPasteImages: { datas in
                    addImages(ImageTools.save(datas, in: store), to: key)
                    focused = true
                }, minHeight: 24, maxLines: 10).disabled(topic.deleted || store.isReadOnly)
                Button { submit(topic) } label: { Image(systemName: "arrow.turn.down.left") }
                    .buttonStyle(HitAreaButtonStyle())
                    .disabled(topic.deleted || store.isReadOnly || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(error.hasPrefix("已") ? Palette.success : Palette.deadline)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func submit(_ topic: JournalStore.NoteTopic) {
        let key = taskDraftKey(topic.id)
        let draft = nav.draft(key)
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draft.images.isEmpty else { return }
        do {
            let command = try store.quickLog(text, images: draft.images, taskID: topic.id, on: Date())
            guard case .entry = command else { error = "这里只能写笔记，不支持 \(text) 这类命令。"; return }
            nav.clearDraft(key)
            error = nil
            focused = true
            ImageIndexer.run(store: store)
        } catch { self.error = error.localizedDescription }
    }

    private func kindColor(_ kind: DailyLogKind) -> Color {
        switch kind {
        case .note: return Palette.muted
        case .done: return Palette.success
        case .block: return Palette.deadline
        case .plan: return Palette.accent
        }
    }

    private static func time(_ date: Date) -> String {
        let parts = JournalDates.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// 笔记导出为 Markdown：按日期分组，图片引用 Images 文件夹里的文件名。
    static func markdown(_ topic: JournalStore.NoteTopic, notes: [JournalStore.LoggedLog]) -> String {
        var lines = ["# \(topic.number.map { "#\($0) " } ?? "")\(topic.title)", ""]
        for group in Dictionary(grouping: notes, by: \.key).sorted(by: { $0.key < $1.key }) {
            lines.append("## \(group.key)")
            for item in group.value {
                let log = item.log
                var line = "- \(time(log.createdAt)) [\(log.kind.label)] \(String(TaskText.rendered(log.text).characters))"
                for name in log.images { line += "\n  ![](Images/\(name))" }
                lines.append(line)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
