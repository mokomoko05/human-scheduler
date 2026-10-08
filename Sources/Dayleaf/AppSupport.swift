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
}

/// 界面字号倍数。基准字号在各处保持原样，渲染时统一乘以倍数。
enum UIScale {
    static var factor: CGFloat {
        let value = UserDefaults.standard.double(forKey: Prefs.uiScale)
        return value == 0 ? 1 : CGFloat(value)
    }

    static func pt(_ value: CGFloat) -> CGFloat { value * factor }
}

/// 菜单栏、键盘和通知发给主界面的命令。
enum AppCommand {
    case newTodo, newLog, insertLink, today, search
    case shiftDay(Int), shiftMonth(Int)
    case agenda(AgendaFilter)
    case toggleTasks, toggleTerminal, rollover
    case selectAdjacent(Int), toggleSelected, editSelected, deleteSelected, deselect
    case reveal(UUID)
    case export, backups, settings, quickCapture, notes, toggleNotes
    /// 全局快捷键触发：`appWasActive` 为 false 表示按键时 Scheduler 在后台，此时只把笔记调到最前面。
    case notesHotKey(appWasActive: Bool)
}

@MainActor
final class CommandCenter: ObservableObject {
    let subject = PassthroughSubject<AppCommand, Never>()
    func send(_ command: AppCommand) { subject.send(command) }
}

/// 窗口底部短暂出现的反馈条，可带一个操作（通常是「撤销」）。
@MainActor
final class ToastCenter: ObservableObject {
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
