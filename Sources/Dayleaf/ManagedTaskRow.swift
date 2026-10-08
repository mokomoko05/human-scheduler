import AppKit
import SwiftUI
import DayleafCore

struct ManagedTaskRow: View {
    @ObservedObject var store: JournalStore
    @EnvironmentObject private var interaction: WorkspaceInteraction
    @ObservedObject private var dragSession = TaskDragSession.shared
    @Environment(\.focusSession) private var focus
    @Environment(\.taskReorder) private var reorder
    let date: Date
    let task: Todo
    var compact = false
    @Binding var requestedEdit: UUID?
    /// 截止日期正好是日历里选中的那一天时，左侧加一条强调线。
    var emphasized = false
    var next: () -> Void = {}
    var select: () -> Void = {}
    @State private var showingDetails = false
    @State private var showingTags = false

    private var selected: Bool { interaction.selectedTaskID == task.id || dragSession.activeID == task.id }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Button { selectTask(); store.toggleTodo(task.id, on: date) } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: UIScale.pt(compact ? 14 : 17), weight: .light))
                    .foregroundStyle(task.completed ? Palette.success : Palette.muted)
                    .frame(width: 18, height: 22)
                    .id(task.completed)
                    .transition(Motion.reduced ? .identity : .scale(scale: 0.4).combined(with: .opacity))
                    .animation(Motion.spring, value: task.completed)
            }
            .buttonStyle(HitAreaButtonStyle())
            .accessibilityLabel((task.completed ? "标记未完成：" : "标记完成：") + task.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 1) {
                    if let number = task.number {
                        Text("#\(number)").font(.system(size: UIScale.pt(10), design: .monospaced))
                            .foregroundStyle(Palette.muted).padding(.top, 7).fixedSize()
                    }
                TaskTitleView(title: Binding(
                    get: { store.entry(for: date).todos.first(where: { $0.id == task.id })?.title ?? task.title },
                    set: { store.renameTodo(task.id, title: $0, on: date) }
                ), completed: task.completed, color: Palette.ink, fontSize: compact ? 12 : 14,
                              next: next, itemID: task.id, requestedEdit: $requestedEdit,
                              prepare: selectTask)
                }
                if task.dueDate != nil || task.repeatRule != .none || task.focusSeconds >= 1 || focus?.active?.taskID == task.id || !task.tags.isEmpty {
                    HStack(spacing: 4) {
                        if let due = task.dueDate {
                            Image(systemName: "clock")
                            Text(dueText(due))
                        }
                        if task.reminderMinutes != nil { Image(systemName: "bell") }
                        if task.repeatRule != .none { Image(systemName: "repeat") }
                        if let focus { FocusTimeBadge(session: focus, taskID: task.id, accumulated: task.focusSeconds) }
                        TaskTagLine(tags: task.tags)
                    }
                    .font(.system(size: UIScale.pt(10))).lineLimit(1)
                    .foregroundStyle(overdue ? Palette.deadline : Palette.muted)
                    .padding(.horizontal, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                if let focus, !task.completed, let url = FocusSession.link(in: task.title) {
                    FocusPlayButton(session: focus, task: ScheduledTask(date: date, task: task), url: url)
                }
                ItemActionButton(symbol: task.tags.isEmpty ? "tag" : "tag.fill", title: "标签") {
                    selectTask()
                    NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
                    showingTags = true
                }
                .popover(isPresented: $showingTags, arrowEdge: .leading) { TagPickerView(store: store, task: task) }
                ItemActionButton(symbol: "calendar.badge.clock", title: "截止日期与月历短标题") {
                    selectTask()
                    NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
                    showingDetails = true
                }
                ItemActionButton(symbol: "trash", title: "删除任务 · ⌘Z 撤销", destructive: true) {
                    NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
                    store.deleteTodo(task.id, on: date)
                    if interaction.selectedTaskID == task.id { interaction.selectedTaskID = nil }
                }
                TaskDragHandle(task: task, enabled: !store.isReadOnly, select: { reorder?.suppressScroll = true; selectTask() }, reorder: reorder.map { model in
                    TaskReorderHooks(begin: { model.begin(task.id) }, update: { model.update($0) },
                                     end: { model.finish() }, cancel: { model.cancel() })
                })
            }
            .fixedSize()
        }
        .padding(.horizontal, 6).padding(.vertical, compact ? 4 : 7)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if emphasized { Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, 6).allowsHitTesting(false) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Palette.accent : .clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .simultaneousGesture(TapGesture().onEnded { selectTask() })
        .animation(.easeInOut(duration: 0.12), value: selected)
        .modifier(TaskDragSource(task: task, enabled: !store.isReadOnly, select: selectTask))
        .popover(isPresented: $showingDetails, arrowEdge: .leading) { TaskDetailsView(store: store, task: task, date: date) }
        .disabled(store.isReadOnly)
    }

    private var overdue: Bool { !task.completed && task.effectiveDeadline.map { $0 < Date() } == true }

    private func dueText(_ due: Date) -> String {
        var text = due.relativeLabel
        if task.dueHasTime {
            let parts = JournalDates.calendar.dateComponents([.hour, .minute], from: due)
            text += String(format: " %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        return overdue ? text + " · 已逾期" : text
    }

    private func selectTask() {
        interaction.selectedTaskID = task.id
        select()
    }
}
