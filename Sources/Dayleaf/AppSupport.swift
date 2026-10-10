import AppKit
import Combine
import SwiftUI
import DayleafCore

/// 偏好设置的存储键；设置窗口、菜单栏和主界面共用。
enum Prefs {
    static let hideCompleted = "hideCompleted"
    static let clickExpands = "clickExpandsTasks"
    static let weekStartsSunday = "weekStartsSunday"
    static let uiScale = "uiScale"
    static let globalHotKey = "globalHotKeyEnabled"
    /// 新建终端的布局：threePanes（左上下两格、右一栏）或 single。
    static let terminalLayout = "terminalLayout"
    /// 专注不足这么多分钟就不在日志里留记录（0 表示都记）。
    static let focusMinLogMinutes = "focusMinLogMinutes"
    static let defaultFocusMinLogMinutes = 5
    /// 专注计时窗口的样式（`FocusPanelStyle.rawValue`）和是否隐藏（专注照常进行，只是不显示）。
    static let focusPanelStyle = "focusPanelStyle"
    static let focusPanelHidden = "focusPanelHidden"
    /// 浮动计时窗口被拖到哪里：窗口左上角。
    static let focusPanelTopLeft = "focusPanelTopLeft"
    static var focusMinLogSeconds: TimeInterval {
        let defaults = UserDefaults.standard
        let minutes = defaults.object(forKey: focusMinLogMinutes) == nil ? defaultFocusMinLogMinutes : defaults.integer(forKey: focusMinLogMinutes)
        return TimeInterval(max(0, minutes) * 60)
    }
}

/// 界面字号倍数。基准字号在各处保持原样，渲染时统一乘以倍数。
enum UIScale {
    static var factor: CGFloat {
        let value = UserDefaults.standard.double(forKey: Prefs.uiScale)
        return value == 0 ? 1 : CGFloat(value)
    }

    static func pt(_ value: CGFloat) -> CGFloat { value * factor }
}

private struct AppCommandsKey: EnvironmentKey {
    static let defaultValue: CommandCenter? = nil
}

extension EnvironmentValues {
    /// 视图里可选地拿到命令中心（不像 @EnvironmentObject 那样缺了就崩溃，搜索面板等地方可以没有）。
    var appCommands: CommandCenter? {
        get { self[AppCommandsKey.self] }
        set { self[AppCommandsKey.self] = newValue }
    }
}

/// 菜单栏、键盘和通知发给主界面的命令。
enum AppCommand {
    /// 选中的任务：打开截止日期、标签面板；固定、放弃、开始专注、打开笔记（键盘也能做到扇形菜单里的事）。
    case deadlineSelected, tagsSelected, pinSelected, dropSelected, focusSelected, notesSelected
    case newTodo, newLog, insertLink, today, search
    case shiftDay(Int), shiftMonth(Int)
    case agenda(AgendaFilter)
    case toggleTasks, toggleDayLog, rollover
    case selectAdjacent(Int), toggleSelected, editSelected, deleteSelected, deselect
    case reveal(UUID)
    case export, backups, settings, quickCapture, notes, toggleNotes
    /// 全局快捷键触发：`appWasActive` 为 false 表示按键时 Scheduler 在后台，此时只把笔记调到最前面。
    case notesHotKey(appWasActive: Bool)
    /// 打开某个任务的笔记（扇形菜单、右键菜单）。
    case notesForTask(UUID)
}

/// 别的窗口（笔记、日志）要动主窗口时用的入口；由 AppDelegate 设置，测试里都是空操作。
@MainActor
enum AppRouter {
    /// 把主窗口调到前面（它可能被收起了）。
    static var presentMain: () -> Void = {}
    /// 主窗口是不是当前的键盘窗口。
    static var mainIsKey: () -> Bool = { true }
    static var showSettings: () -> Void = {}
    static var showQuickCapture: () -> Void = {}
    /// 打开某个任务的笔记。
    static var openNotes: (UUID) -> Void = { _ in }
}

@MainActor
final class CommandCenter: ObservableObject {
    let subject = PassthroughSubject<AppCommand, Never>()
    func send(_ command: AppCommand) { subject.send(command) }
}

/// 窗口底部短暂出现的反馈条，可带一个操作（通常是「撤销」）。
@MainActor
final class ToastCenter: ObservableObject {
    /// 哪些操作完成后要给一个带「撤销」的提示，以及提示的文字。
    static let undoMessages = ["删除任务": "已删除事项", "删除日志": "已删除日志", "移动任务": "已移动事项", "移到今天": "已把逾期事项的截止日期改到今天",
                               "完成状态": "已更新完成状态", "放弃待办": "已放弃", "恢复待办": "已恢复", "重命名标签": "已重命名标签", "删除标签": "已删除标签（内容都保留）"]
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?
    }

    @Published private(set) var current: Toast?
    private var dismissal: Task<Void, Never>?

    func show(_ message: String, actionTitle: String? = nil, duration: TimeInterval = 5, action: (() -> Void)? = nil) {
        let toast = Toast(message: message, actionTitle: actionTitle, action: action)
        current = toast
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self?.current?.id == toast.id { self?.current = nil }
        }
    }

    func dismiss() {
        dismissal?.cancel()
        current = nil
    }
}

struct ToastView: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        Group {
            if let toast = center.current {
                HStack(spacing: 12) {
                    Text(toast.message).font(.system(size: UIScale.pt(12), weight: .medium)).lineLimit(1)
                    if let title = toast.actionTitle, let action = toast.action {
                        Button(title) { action(); center.dismiss() }
                            .buttonStyle(HitAreaButtonStyle(compact: true))
                            .font(.system(size: UIScale.pt(12), weight: .semibold))
                            .foregroundStyle(Palette.accent)
                    }
                    Button { center.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(HitAreaButtonStyle(compact: true)).foregroundStyle(Palette.muted)
                        .accessibilityLabel("关闭提示")
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.line))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(Motion.spring, value: center.current?.id)
    }
}

enum Motion {
    /// 测试里一律按「减少动态效果」处理：淡入淡出和弹簧动画立刻完成，不依赖屏幕是否亮着。
    static var reduced: Bool { Headless.active || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var spring: Animation? { reduced ? nil : .spring(response: 0.3, dampingFraction: 0.85) }
    static var quick: Animation? { reduced ? nil : .easeOut(duration: 0.16) }
}

extension Date {
    /// 「今天 / 明天 / 10月8日」之类的短标签。
    var relativeLabel: String {
        let calendar = JournalDates.calendar
        if calendar.isDateInToday(self) { return "今天" }
        if calendar.isDateInTomorrow(self) { return "明天" }
        if calendar.isDateInYesterday(self) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.isDate(self, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: self)
    }
}
