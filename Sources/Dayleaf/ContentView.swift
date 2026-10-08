import AppKit
import Combine
import SwiftUI
import DayleafCore
import UniformTypeIdentifiers

enum Palette {
    static let background = adaptive(0xF6F8FA, 0x0D1117)
    static let card = adaptive(0xFFFFFF, 0x161B22)
    static let ink = adaptive(0x1F2328, 0xF0F6FC)
    static let muted = adaptive(0x59636E, 0x9198A1)
    static let accent = adaptive(0x0969DA, 0x4493F8)
    static let soft = adaptive(0xDDF4FF, 0x121D2F)
    static let line = adaptive(0xD1D9E0, 0x3D444D)
    static let success = adaptive(0x1A7F37, 0x3FB950)
    static let deadline = adaptive(0xBC4C00, 0xD29922)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.vertical, 8)
    }
}

struct ContentView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var loginItem: LoginItem
    @State private var selectedDate = JournalDates.calendar.startOfDay(for: Date())
    @State private var displayedMonth = JournalDates.monthStart(Date())
    @State private var actionError: String?
    @State private var showingLinkComposer = false
    @State private var linkInsertion: LinkInsertion?
    @State private var pendingLink: String?
    @State private var agenda: AgendaFilter?
    @State private var showingBackups = false
    @State private var requestedEdit: UUID?
    @State private var showingMonthJumper = false
    private let notesWindow = NotesWindowController.shared
    /// 刻意用 @State 而不是 @StateObject：拖动时模型每秒更新几十次，ContentView 不能订阅它，否则整个界面都会跟着重绘。只有被拖的那一行和让位的行订阅。
    @State private var reorder = TaskReorderModel()
    @State private var overdueCount = 0
    @State private var scrollTarget: UUID?
    @AppStorage(Prefs.hideCompleted) private var hideCompleted = false
    @AppStorage(Prefs.clickExpands) private var clickExpands = true
    @AppStorage(Prefs.weekStartsSunday) private var weekStartsSunday = false
    @AppStorage(Prefs.uiScale) private var uiScale = 1.0
    @EnvironmentObject private var reminders: ReminderScheduler
    @EnvironmentObject private var interaction: WorkspaceInteraction
    @EnvironmentObject private var commands: CommandCenter
    @EnvironmentObject private var toast: ToastCenter
    @State private var currentDayKey = JournalDates.key(Date())
    @State private var addingTodo = false
    @AppStorage("tasksPaneExpanded") private var tasksVisible = false
    @AppStorage("terminalPaneExpanded") private var terminalVisible = true
    private let dayTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private var entry: DayEntry { store.entry(for: selectedDate) }
    /// 全部任务（不属于某一天），按截止时间排序；隐藏已完成时过滤掉已完成的。
    private var visibleTasks: [ScheduledTask] { store.sortedTasks().filter { !hideCompleted || !$0.task.completed } }
    /// 终端只对今天及以前的日期开放；未来的日期不显示。
    private var terminalAvailable: Bool {
        selectedDate <= JournalDates.calendar.startOfDay(for: Date())
    }
    private var weekStart: Int { weekStartsSunday ? 1 : 2 }
    private var footerVisible: Bool { store.errorMessage != nil || !reminders.status.isEmpty }
    private var draft: Binding<String> {
        Binding(get: { entry.deadlineDraft }, set: { store.setDeadlineDraft($0, on: selectedDate) })
    }

    /// 带「撤销」提示的操作。普通编辑不打扰用户。
    private static let toastMessages = ["删除任务": "已删除事项", "删除日志": "已删除日志", "移动任务": "已移动事项", "移到今天": "已把逾期事项的截止日期改到今天"]

    var body: some View {
        VStack(spacing: 0) {
            ResizableWorkspace(tasksVisible: $tasksVisible, terminalVisible: $terminalVisible, terminalAvailable: terminalAvailable) {
                VStack(alignment: .leading, spacing: 16) {
                    dateHeader
                    todoCard
                }
                .padding(16)
                .simultaneousGesture(TapGesture().onEnded { interaction.activePane = .tasks })
            } summary: {
                summaryCard.padding(16)
                    .background(TerminalPalette.panel)
                    .simultaneousGesture(TapGesture().onEnded { interaction.activePane = .summary })
            } calendar: {
                calendarCard.padding(16)
            }
            if footerVisible { footer.transition(.opacity) }
        }
        .id(uiScale)
        .animation(Motion.quick, value: footerVisible)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .frame(minWidth: 640, minHeight: 560)
        .overlay(alignment: .bottom) {
            ToastView(center: toast).padding(.bottom, footerVisible ? 52 : 18)
        }
        .sheet(isPresented: $showingLinkComposer, onDismiss: {
            if linkInsertion?.finish(inserting: pendingLink) != true {
                if let pendingLink { draft.wrappedValue += (draft.wrappedValue.isEmpty ? "" : " ") + pendingLink }
                tasksVisible = true
                addingTodo = true
            }
            pendingLink = nil
            linkInsertion = nil
        }) {
            LinkComposer(insert: { pendingLink = $0 }, initialAddress: linkInsertion?.initialAddress ?? "", initialLabel: linkInsertion?.initialLabel ?? "")
        }
        .sheet(item: $agenda) { filter in
            AgendaView(store: store, navigate: { date, id in reveal(date: date, taskID: id) }, filter: filter)
        }
        .sheet(isPresented: $showingBackups) { BackupRestoreView(store: store) }
        .alert("暂时无法完成操作", isPresented: Binding(
            get: { actionError != nil || loginItem.errorMessage != nil },
            set: { if !$0 { actionError = nil; loginItem.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { actionError = nil; loginItem.errorMessage = nil }
        } message: {
            Text(actionError ?? loginItem.errorMessage ?? "")
        }
        .onAppear {
            refreshOverview()
            reorder.groupProvider = { id in groups(for: visibleTasks).first { $0.items.contains { $0.id == id } }?.items.map(\.id) ?? [] }
            reorder.commit = { store.reorderTasks($0) }
        }
        .onReceive(dayTimer) { now in
            refreshOverview()
            let newKey = JournalDates.key(now)
            guard currentDayKey != newKey else { return }
            if JournalDates.key(selectedDate) == currentDayKey { select(now) }
            currentDayKey = newKey
        }
        .onReceive(store.$days.debounce(for: .milliseconds(400), scheduler: RunLoop.main)) { _ in refreshOverview() }
        .onReceive(store.$lastAction.dropFirst()) { event in
            toast.dismiss()
            guard let event, let message = Self.toastMessages[event.name] else { return }
            toast.show(message, actionTitle: "撤销") { store.undo() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            reminders.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dayleafNavigate)) { if let date = $0.object as? Date { select(date) } }
        .onReceive(NotificationCenter.default.publisher(for: .dayleafReveal)) { if let id = $0.object as? UUID { reveal(date: store.locate(id)?.task.dueDate, taskID: id) } }
        .onReceive(NotificationCenter.default.publisher(for: .dayleafOpenTag)) { if let tag = $0.object as? String { showNotes(tag: tag) } }
        .onReceive(commands.subject) { handle($0) }
    }

    // MARK: - 命令

    /// 打开笔记窗口：指定标签就定位到标签；否则选中的任务有笔记就直接定位到它，没有就打开最近有笔记的那个。
    private func showNotes(tag: String?) {
        let selected = interaction.selectedTaskID
        notesWindow.show(store: store, taskID: store.noteTopics().contains { $0.id == selected } ? selected : nil, tag: tag,
                         reveal: { id in reveal(date: store.locate(id)?.task.dueDate, taskID: id) },
                         openDay: { select($0) })
    }

    private func handle(_ command: AppCommand) {
        switch command {
        case .newTodo:
            tasksVisible = true
            interaction.activePane = .tasks
            addingTodo = true
        case .newLog:
            if !terminalAvailable { select(Date()) }
            terminalVisible = true
            interaction.activePane = .summary
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { interaction.logFocusRequest += 1 }
        case .insertLink:
            guard !store.isReadOnly else { return }
            linkInsertion = LinkInsertion()
            showingLinkComposer = true
        case .today: select(Date())
        case .search: agenda = .all
        case .notes: showNotes(tag: nil)
        case .notesHotKey(let appWasActive):
            if !notesWindow.isVisible { showNotes(tag: nil) }
            else if appWasActive { notesWindow.close() }
            else { notesWindow.window?.makeKeyAndOrderFront(nil) }
        case .toggleNotes:
            if notesWindow.isVisible { notesWindow.close() } else { showNotes(tag: nil) }
        case .agenda(let filter): agenda = filter
        case .shiftDay(let amount): shiftDay(amount)
        case .shiftMonth(let amount): shiftMonth(amount)
        case .toggleTasks: toggleTasks()
        case .toggleTerminal:
            guard terminalAvailable else { toast.show("终端只在今天及以前的日期可用"); return }
            NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
            // 终端高度变化会让整个月历重新布局，动画会逐帧重算，所以瞬间切换。
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { terminalVisible.toggle() }
            if terminalVisible {
                interaction.activePane = .summary
                DispatchQueue.main.async { interaction.logFocusRequest += 1 }
            }
        case .rollover: rolloverToday()
        case .selectAdjacent(let amount): moveSelection(amount)
        case .toggleSelected:
            if let task = selectedTask { store.toggleTodo(task.id, on: task.date) }
        case .editSelected:
            guard let task = selectedTask else { return }
            tasksVisible = true
            requestedEdit = task.id
        case .deleteSelected:
            guard let task = selectedTask else { return }
            let neighbours = visibleTasks.map(\.task)
            let index = neighbours.firstIndex { $0.id == task.id }
            store.deleteTodo(task.id, on: task.date)
            interaction.selectedTaskID = index.flatMap { i in
                (i + 1 < neighbours.count ? neighbours[i + 1] : (i > 0 ? neighbours[i - 1] : nil))?.id
            }
        case .deselect: interaction.selectedTaskID = nil
        case .reveal(let id): reveal(date: store.locate(id)?.task.dueDate, taskID: id)
        case .export: exportJournal()
        case .backups: showingBackups = true
        case .settings, .quickCapture: break
        }
    }

    private var selectedTask: ScheduledTask? { interaction.selectedTaskID.flatMap(store.locate) }

    private func sameDay(_ a: Date, _ b: Date) -> Bool { JournalDates.calendar.isDate(a, inSameDayAs: b) }

    private func reveal(date: Date?, taskID: UUID?) {
        if let date { select(date) }
        interaction.selectedTaskID = taskID
    }

    private func moveSelection(_ amount: Int) {
        let list = visibleTasks.map(\.task)
        guard !list.isEmpty else { return }
        tasksVisible = true
        interaction.activePane = .tasks
        if let id = interaction.selectedTaskID, let index = list.firstIndex(where: { $0.id == id }) {
            interaction.selectedTaskID = list[min(max(index + amount, 0), list.count - 1)].id
        } else {
            interaction.selectedTaskID = (amount > 0 ? list.first : list.last)?.id
        }
    }

    private func rolloverToday() {
        guard store.rolloverUnfinished(to: Date()) > 0 else {
            toast.show("没有逾期的事项")
            return
        }
        select(Date())
    }

    private func refreshOverview() {
        let now = Date()
        overdueCount = store.overdueCount(now: now)
        NSApp.dockTile.badgeLabel = overdueCount > 0 ? "\(overdueCount)" : nil
    }

    // MARK: - 头部与清单

    private var optionsMenu: some View {
        Menu {
            Button("新建待办") { commands.send(.newTodo) }
            Button("快速记录…") { commands.send(.quickCapture) }
            Button("插入链接…") { commands.send(.insertLink) }.disabled(store.isReadOnly)
            Divider()
            Button("搜索任务、日志与总结…") { commands.send(.search) }
            Button("笔记…") { commands.send(.notes) }
            Button("未完成事项…") { agenda = .unfinished }
            Button("即将截止…") { agenda = .upcoming }
            Button("已逾期…") { agenda = .overdue }
            if overdueCount > 0 {
                Button("把 \(overdueCount) 项逾期事项的截止日期改到今天") { rolloverToday() }
            }
            Divider()
            Toggle("隐藏已完成", isOn: $hideCompleted)
            Toggle("单击日期时展开待办清单", isOn: $clickExpands)
            Divider()
            Button("导出为文件夹…", action: exportJournal).disabled(store.isReadOnly)
            Button("备份与恢复…") { showingBackups = true }
            Button("设置…") { commands.send(.settings) }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: UIScale.pt(19))).foregroundStyle(Palette.muted)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 34)
        .help("更多选项")
        .accessibilityLabel("更多选项")
    }

    private var dateHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(format(selectedDate, "M月d日"))
                        .font(.system(size: UIScale.pt(26), weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if JournalDates.calendar.isDateInToday(selectedDate) {
                        Text("今天").font(.system(size: UIScale.pt(11), weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Palette.soft, in: Capsule())
                            .foregroundStyle(Palette.accent)
                    } else {
                        Button("回到今天") { select(Date()) }
                            .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: UIScale.pt(11), weight: .medium))
                            .foregroundStyle(Palette.accent).help("回到今天 · ⌘T")
                    }
                }
                Text(format(selectedDate, "yyyy年 · EEEE"))
                    .font(.system(size: UIScale.pt(12))).foregroundStyle(Palette.muted)
                    .lineLimit(1).fixedSize()
                overviewChip
            }
            Spacer()
            HStack(spacing: 12) {
                navigationButton("chevron.left", help: "前一天 · ⌥⌘←") { shiftDay(-1) }
                navigationButton("chevron.right", help: "后一天 · ⌥⌘→") { shiftDay(1) }
                navigationButton("sidebar.left", help: "收起待办清单 · ⌘\\") { toggleTasks() }
            }
        }
        .padding(.vertical, 2)
    }

    /// 逾期事项的入口：查看，或一键把它们的截止日期改到今天。
    @ViewBuilder
    private var overviewChip: some View {
        if overdueCount > 0 {
            Menu {
                Button("查看已逾期事项（\(overdueCount)）…") { agenda = .overdue }
                Button("把 \(overdueCount) 项逾期事项的截止日期改到今天") { rolloverToday() }
            } label: {
                Label("逾期 \(overdueCount)", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.deadline.opacity(0.14), in: Capsule())
                    .foregroundStyle(Palette.deadline)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("查看逾期事项，或把它们的截止日期改到今天")
        }
    }

    /// 任务分组：已逾期、今天、明天、未来 7 天、更晚、未设截止日期、已完成。
    private struct TaskGroup: Identifiable {
        let id: String
        let title: String
        let tint: Color
        let items: [ScheduledTask]
    }

    private func groups(for tasks: [ScheduledTask]) -> [TaskGroup] {
        let calendar = JournalDates.calendar
        let now = Date()
        let today = calendar.startOfDay(for: now)
        func days(_ task: Todo) -> Int? {
            task.dueDate.map { calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: $0)).day ?? 0 }
        }
        let open = tasks.filter { !$0.task.completed }
        let specs: [(String, String, Color, (ScheduledTask) -> Bool)] = [
            ("overdue", "已逾期", Palette.deadline, { $0.task.effectiveDeadline.map { $0 < now } == true }),
            ("today", "今天", Palette.accent, { item in (days(item.task) ?? 1) == 0 && !(item.task.effectiveDeadline.map { $0 < now } == true) }),
            ("tomorrow", "明天", Palette.ink, { days($0.task) == 1 }),
            ("week", "未来 7 天", Palette.ink, { (2...7).contains(days($0.task) ?? 0) }),
            ("later", "更晚", Palette.muted, { (days($0.task) ?? 0) > 7 }),
            ("undated", "未设截止日期", Palette.muted, { $0.task.dueDate == nil }),
        ]
        var result = specs.compactMap { id, title, tint, belongs -> TaskGroup? in
            let items = open.filter(belongs)
            return items.isEmpty ? nil : TaskGroup(id: id, title: title, tint: tint, items: items)
        }
        let done = tasks.filter { $0.task.completed }
        if !done.isEmpty { result.append(TaskGroup(id: "done", title: "已完成", tint: Palette.success, items: done)) }
        return result
    }

    private var todoCard: some View {
        let all = store.sortedTasks()
        let visible = all.filter { !hideCompleted || !$0.task.completed }
        let completed = all.filter(\.task.completed).count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "checklist").foregroundStyle(Palette.accent)
                Text("待办清单").font(.system(size: UIScale.pt(16), weight: .semibold))
                    .foregroundStyle(interaction.activePane == .tasks ? Palette.accent : Palette.ink)
                Spacer()
                let hidden = hideCompleted ? completed : 0
                if hidden > 0 {
                    Button { hideCompleted = false } label: {
                        Label("已隐藏 \(hidden) 项", systemImage: "eye.slash")
                            .font(.system(size: UIScale.pt(11)))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Palette.soft, in: Capsule())
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                    .help("已完成的事项被隐藏，点击显示").accessibilityLabel("显示已隐藏的 \(hidden) 项已完成事项")
                }
                Text("\(completed) / \(all.count)")
                    .font(.system(size: UIScale.pt(12), weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }
            ProgressView(value: Double(completed), total: Double(max(all.count, 1)))
                .tint(Palette.success)
                .animation(Motion.quick, value: completed)
                .accessibilityLabel("待办完成进度")
            if visible.isEmpty {
                emptyState(hasHidden: !all.isEmpty)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // 不用 LazyVStack：排序拖动要知道同一分组里每一行的位置，行不能是懒加载的。
                        VStack(alignment: .leading, spacing: TaskReorderModel.spacing) {
                            ForEach(groups(for: visible)) { group in
                                HStack(spacing: 6) {
                                    Text(group.title).font(.system(size: UIScale.pt(12), weight: .semibold)).foregroundStyle(group.tint)
                                    Text("\(group.items.count)").font(.system(size: UIScale.pt(11), design: .monospaced)).foregroundStyle(Palette.muted)
                                    Rectangle().fill(Palette.line).frame(height: 1)
                                }
                                .padding(.top, 8).padding(.horizontal, 2)
                                ForEach(group.items) { item in
                                    ManagedTaskRow(store: store, date: item.date, task: item.task, requestedEdit: $requestedEdit,
                                                   emphasized: dueOnSelectedDay(item.task),
                                                   next: { addingTodo = true }, select: { interaction.activePane = .tasks })
                                        .id(item.id)
                                        .taskReorderRow(id: item.id, model: reorder, space: "taskList")
                                }
                            }
                            Color.clear.frame(height: 12)
                        }
                        .coordinateSpace(name: "taskList")
                        .environment(\.taskReorder, store.isReadOnly ? nil : reorder)
                        .onPreferenceChange(TaskRowFramesKey.self) { reorder.frames = $0 }
                    }
                    .onChange(of: scrollTarget) { id in
                        if let id { withAnimation(Motion.quick) { proxy.scrollTo(id, anchor: .center) }; scrollTarget = nil }
                    }
                    .onChange(of: requestedEdit) { if let id = $0 { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: interaction.selectedTaskID) { id in
                        if reorder.suppressScroll { reorder.suppressScroll = false; return }
                        if let id { withAnimation(Motion.quick) { proxy.scrollTo(id) } }
                    }
                    // 在日历里选了某一天：清单滚动到那天截止的第一项。
                    .onChange(of: selectedDate) { _ in
                        if let first = visible.first(where: { dueOnSelectedDay($0.task) }) {
                            withAnimation(Motion.quick) { proxy.scrollTo(first.id, anchor: .top) }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "plus").foregroundStyle(Palette.accent)
                    TaskInput(text: draft, focused: $addingTodo, placeholder: "添加待办，之后再分配截止日期", submit: addTodo,
                              cancel: { addingTodo = false }, previous: {
                        if let newest = visible.max(by: { ($0.task.number ?? 0) < ($1.task.number ?? 0) }) {
                            addingTodo = false
                            requestedEdit = newest.id
                        }
                    }, minHeight: UIScale.pt(22), maxLines: 6, allowsNewlines: false)
                        .help("回车添加。先创建，之后再用日历按钮或拖到日历上分配截止日期；也可以直接写「明天 15:00 开会」「每周一」「提前30分钟」，加 #标签 归类。支持 [别名](https://网址)，⌘K 插入链接")
                    Button(action: addTodo) {
                        Image(systemName: "arrow.turn.down.left")
                            .font(.system(size: UIScale.pt(11), weight: .semibold))
                            .padding(7).background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(HitAreaButtonStyle())
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("添加待办")
                }
                let parsed = QuickAdd.parse(draft.wrappedValue)
                if parsed.hasSchedule || !parsed.tags.isEmpty { ParsedChips(parsed: parsed, dayIsDeadline: true).transition(.opacity) }
            }
            .padding(11)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
            .animation(Motion.quick, value: QuickAdd.parse(draft.wrappedValue).hasSchedule || !QuickAdd.parse(draft.wrappedValue).tags.isEmpty)
        }
        .disabled(store.isReadOnly)
        .modifier(Card())
        .frame(maxHeight: .infinity)
    }

    private func dueOnSelectedDay(_ task: Todo) -> Bool {
        task.dueDate.map { sameDay($0, selectedDate) } == true
    }

    private func emptyState(hasHidden: Bool) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: hasHidden ? "eye.slash" : "leaf")
                .font(.system(size: 30, weight: .light)).foregroundStyle(Palette.muted.opacity(0.6))
            Text(hasHidden ? "已完成的事项已隐藏" : "还没有待办")
                .font(.system(size: UIScale.pt(14), weight: .medium))
            Text("在下方输入添加。先创建，之后再分配截止日期：\n点任务右侧的日历按钮，或把它拖到日历上。")
                .font(.system(size: UIScale.pt(12))).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
    }

    private var summaryCard: some View {
        DailyLogView(store: store, date: selectedDate, collapse: {
            NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
            terminalVisible = false
        }).id(JournalDates.key(selectedDate))
    }

    // MARK: - 月历

    private var calendarCard: some View {
        let dates = JournalDates.monthGrid(displayedMonth, weekStart: weekStart)
        let dueByDay = store.calendarDeadlines
        let previews = dates.map { date in
            DeadlineDayCell.previewItems(dueItems: dueByDay[JournalDates.key(date)] ?? [], hideCompleted: hideCompleted)
        }
        let rowCount = CGFloat(dates.count / 7)
        let weekdays = Array(["日", "一", "二", "三", "四", "五", "六"].enumerated())
        let ordered = (0..<7).map { weekdays[($0 + weekStart - 1) % 7].element }
        return VStack(spacing: 12) {
            HStack {
                if !tasksVisible {
                    navigationButton("sidebar.left", help: "展开所选日期的待办清单 · ⌘\\") { toggleTasks() }
                    selectedDayChip
                }
                Button { showingMonthJumper = true } label: {
                    HStack(spacing: 4) {
                        Text(format(displayedMonth, "yyyy年 M月"))
                            .font(.system(size: UIScale.pt(16), weight: .semibold, design: .rounded))
                            .foregroundStyle(interaction.activePane == .calendar ? Palette.accent : Palette.ink)
                        Image(systemName: "chevron.down").font(.system(size: UIScale.pt(8), weight: .bold)).foregroundStyle(Palette.muted)
                    }
                }
                .buttonStyle(HitAreaButtonStyle(compact: true))
                .help("点击跳转到任意年月 · 触控板左右轻扫切换月份")
                .accessibilityLabel("选择月份，当前\(format(displayedMonth, "yyyy年M月"))")
                .popover(isPresented: $showingMonthJumper, arrowEdge: .bottom) {
                    MonthJumper(current: displayedMonth) { date in
                        displayedMonth = JournalDates.monthStart(date)
                        showingMonthJumper = false
                    }
                }
                Spacer()
                Button("今天") { select(Date()) }
                    .buttonStyle(HitAreaButtonStyle()).font(.system(size: UIScale.pt(11), weight: .medium))
                    .foregroundStyle(Palette.accent).help("回到今天 · ⌘T")
                Button("未完成") { agenda = .unfinished }.buttonStyle(HitAreaButtonStyle()).font(.system(size: UIScale.pt(11))).foregroundStyle(Palette.accent)
                Button { agenda = .all } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(HitAreaButtonStyle()).help("搜索 · ⌘F").accessibilityLabel("搜索")
                Button { commands.send(.notes) } label: { Image(systemName: "note.text") }
                    .buttonStyle(HitAreaButtonStyle()).help("笔记 · ⇧⌘N").accessibilityLabel("笔记")
                navigationButton("chevron.left", help: "上个月") { shiftMonth(-1) }
                navigationButton("chevron.right", help: "下个月") { shiftMonth(1) }
                optionsMenu
            }
            GeometryReader { geometry in
                let dayHeight = max(80, (geometry.size.height - 22 - 6 * rowCount) / rowCount)
                let weekHeights = stride(from: 0, to: dates.count, by: 7).map { start in
                    max(dayHeight, UIScale.pt(29) + CGFloat(previews[start..<(start + 7)].map(\.count).max() ?? 0) * UIScale.pt(25))
                }
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(ordered, id: \.self) { weekday in
                            Text(weekday).font(.system(size: UIScale.pt(11), weight: .medium))
                                .foregroundStyle(Palette.muted).frame(height: 18)
                        }
                        ForEach(Array(dates.enumerated()), id: \.element) { index, date in
                            DeadlineDayCell(store: store, date: date, selectedDate: selectedDate,
                                            displayedMonth: displayedMonth, height: weekHeights[index / 7],
                                            items: previews[index],
                                            select: { selectFromCalendar(date) },
                                            open: { selectFromCalendar(date, forceExpand: true); addingTodo = true },
                                            editTask: { item in
                                interaction.activePane = .calendar
                                NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
                                tasksVisible = true
                                interaction.selectedTaskID = item.id
                                requestedEdit = item.id
                            })
                        }
                    }
                    .padding(2)
                }
            }
            .frame(minHeight: 120)
        }
        .background(MonthSwipeCatcher { shiftMonth($0) })
    }

    /// 清单收起、单击日期又不展开时，在这里确认当前选中的日期并可一键展开。
    private var selectedDayChip: some View {
        Button { toggleTasks() } label: {
            HStack(spacing: 5) {
                Text(selectedDate.relativeLabel).fontWeight(.semibold)
                let due = store.calendarDeadlines[JournalDates.key(selectedDate)] ?? []
                if !due.isEmpty {
                    Text("\(due.filter(\.task.completed).count)/\(due.count)").font(.system(size: UIScale.pt(10), design: .monospaced))
                }
            }
            .font(.system(size: UIScale.pt(11)))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Palette.soft, in: Capsule())
            .foregroundStyle(Palette.accent)
        }
        .buttonStyle(.plain)
        .help("所选日期，点击展开待办清单").accessibilityLabel("所选日期 \(format(selectedDate, "M月d日"))，展开待办清单")
    }

    private func selectFromCalendar(_ date: Date, forceExpand: Bool = false) {
        interaction.activePane = .calendar
        if !sameDay(date, selectedDate) {
            NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
            selectedDate = JournalDates.calendar.startOfDay(for: date)
        }
        if clickExpands || forceExpand { tasksVisible = true }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 6) {
                if let error = store.errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).lineLimit(2).help(error)
                    if !store.isReadOnly { Button("重试保存", action: store.save).buttonStyle(HitAreaButtonStyle()) }
                    Button("打开数据文件夹") { NSWorkspace.shared.open(store.directory) }.buttonStyle(HitAreaButtonStyle())
                } else {
                    Image(systemName: "bell.slash")
                    Text(reminders.status).lineLimit(2)
                }
                Spacer()
                if !reminders.status.isEmpty {
                    Button("通知设置") { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } }
                        .buttonStyle(HitAreaButtonStyle())
                }
            }
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(Palette.deadline)
            .padding(.horizontal, 30).padding(.vertical, 8)
        }
    }

    private func navigationButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: UIScale.pt(11), weight: .medium))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(HitAreaButtonStyle()).foregroundStyle(Palette.muted).help(help).accessibilityLabel(help)
    }

    private func select(_ date: Date) {
        NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
        tasksVisible = true
        selectedDate = JournalDates.calendar.startOfDay(for: date)
        displayedMonth = JournalDates.monthStart(date)
    }

    private func toggleTasks() {
        NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
        tasksVisible.toggle()
    }

    private func shiftDay(_ amount: Int) {
        if let date = JournalDates.calendar.date(byAdding: .day, value: amount, to: selectedDate) { select(date) }
    }

    private func shiftMonth(_ amount: Int) {
        if let date = JournalDates.calendar.date(byAdding: .month, value: amount, to: displayedMonth) { displayedMonth = date }
    }

    private func addTodo() {
        guard !store.isReadOnly else { return }
        let added = store.commitDraft(on: selectedDate)
        addingTodo = true
        scrollTarget = added.last?.id
        if added.contains(where: { $0.task.reminderMinutes != nil }) {
            Task { @MainActor in
                _ = await reminders.requestPermission()
                reminders.refresh()
            }
        }
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = JournalDates.calendar
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// 导出为文件夹：journal.json 加上日志里用到的全部图片。
    private func exportJournal() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Scheduler 备份-\(JournalDates.key(Date()))"
        panel.canCreateDirectories = true
        panel.message = "将导出为一个文件夹，包含 journal.json 和日志图片（Images）。"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportFolder(to: url)
            toast.show("已导出到「\(url.lastPathComponent)」", actionTitle: "显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch { actionError = error.localizedDescription }
    }
}
