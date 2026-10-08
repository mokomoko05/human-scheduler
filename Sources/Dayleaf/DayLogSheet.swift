import AppKit
import SwiftUI
import DayleafCore

/// ⌘J 打开的当天日志：选中的那一天，按时间顺序列出所有日志，可以在里面写、改、删、关联待办、打标签、批量处理，右边是当天的复盘。
/// 它是主窗口上的 sheet，可以拖边缘调整大小；Esc、⌘J 或「完成」关闭。
struct DayLogSheet: View {
    @ObservedObject var store: JournalStore
    @State private var date: Date
    let close: () -> Void

    init(store: JournalStore, initialDate: Date, close: @escaping () -> Void) {
        self.store = store
        self.close = close
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
        .frame(minWidth: 820, idealWidth: 1040, maxWidth: .infinity, minHeight: 520, idealHeight: 700, maxHeight: .infinity)
        .background(SheetResizer())
        // 点日志里的任务标签会跳到主窗口里的那个任务：先关掉这个 sheet。
        .onReceive(NotificationCenter.default.publisher(for: .dayleafNavigate)) { _ in close() }
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

/// sheet 默认不能调整大小：打开后给它加上 resizable，用户可以拖边缘。
struct SheetResizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.minSize = NSSize(width: 820, height: 520)
        }
    }
}
