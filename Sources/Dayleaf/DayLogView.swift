import AppKit
import SwiftUI
import DayleafCore

/// 当天日志窗口里的内容（⌘J）：选中的那一天，按时间顺序列出所有日志，可以在里面写、改、删、关联待办、打标签、批量处理，右边是当天的复盘。
/// 它在独立窗口里，可以拖边缘调整大小；Esc、⌘J 或「完成」关闭。
struct DayLogView: View {
    @ObservedObject var store: JournalStore
    @State private var date: Date
    let close: () -> Void
    let showMain: () -> Void

    init(store: JournalStore, initialDate: Date, close: @escaping () -> Void, showMain: @escaping () -> Void = {}) {
        self.store = store
        self.close = close
        self.showMain = showMain
        _date = State(initialValue: JournalDates.calendar.startOfDay(for: initialDate))
    }

    private var isToday: Bool { JournalDates.calendar.isDateInToday(date) }

    private func shift(_ days: Int) {
        NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
        date = JournalDates.calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DailyLogView(store: store, date: date, collapse: nil, autoFocus: true)
                .id(JournalDates.key(date))
        }
        .frame(minWidth: DayLogWindowController.minSize.width, maxWidth: .infinity, minHeight: DayLogWindowController.minSize.height, maxHeight: .infinity)
        // 点日志里的任务标签会跳到主窗口里的那个任务：把主窗口调到前面，日志窗口留着。
        .onReceive(NotificationCenter.default.publisher(for: .dayleafNavigate)) { _ in showMain() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.alignleft").foregroundStyle(Palette.accent)
            Text(date.formatted(.dateTime.year().month().day().weekday(.wide))).font(.system(size: 15, weight: .semibold))
            if isToday {
                Text("今天").font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.soft, in: Capsule()).foregroundStyle(Palette.accent)
            } else {
                Button("回到今天") { shift(JournalDates.calendar.dateComponents([.day], from: date, to: JournalDates.calendar.startOfDay(for: Date())).day ?? 0) }
                    .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
            }
            Text("\(store.entry(for: date).logs.count) 条").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Spacer()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(HitAreaButtonStyle()).foregroundStyle(Palette.muted).help("前一天").accessibilityLabel("前一天")
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(HitAreaButtonStyle()).foregroundStyle(Palette.muted).help("后一天").accessibilityLabel("后一天")
            Button("完成") { NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil); close() }
                .keyboardShortcut(.cancelAction).help("关闭 · Esc 或 ⌘J")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
    }
}
