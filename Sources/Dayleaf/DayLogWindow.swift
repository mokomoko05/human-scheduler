import AppKit
import SwiftUI
import DayleafCore

private final class DayLogWindow: QuietWindow {
    /// 没有文字框处理 Esc 时关闭窗口。
    override func cancelOperation(_ sender: Any?) { close() }
}

/// 当天日志窗口（⌘J）：独立窗口，可以拖边缘调整大小；大小和位置会被记住。
/// 和主窗口、笔记、终端互不依赖，各自开关。
@MainActor
final class DayLogWindowController: NSObject, NSWindowDelegate {
    static let defaultFrameName = "DayleafDayLogWindow"
    static let shared = DayLogWindowController()
    /// 窗口大小、位置保存在偏好里的名字（测试里换成独立的名字）。
    let frameName: String

    init(frameName: String = DayLogWindowController.defaultFrameName) {
        self.frameName = frameName
        super.init()
    }
    private(set) var window: NSWindow?
    var interaction = WorkspaceInteraction()
    var toast = ToastCenter()
    /// 关闭后，Scheduler 别的窗口还开着就把焦点交给它；由 AppDelegate 设置。
    var handoffWindow: () -> NSWindow? = { nil }
    /// 点日志里的任务标签跳到主窗口的任务：把主窗口调到前面；由 AppDelegate 设置。
    var showMainWindow: () -> Void = {}

    var isVisible: Bool { window?.isVisible == true }

    /// 打开某一天的日志；已经开着就复用同一个窗口，切到这一天。
    func show(store: JournalStore, date: Date) {
        let window = self.window ?? makeWindow()
        self.window = window
        let view = DayLogView(store: store, initialDate: date, close: { [weak self] in self?.close() },
                              showMain: { [weak self] in self?.showMainWindow() })
            .environmentObject(interaction).environmentObject(toast)
        if let host = window.contentViewController as? NSHostingController<AnyView> {
            host.rootView = AnyView(view.id(UUID()))
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func toggle(store: JournalStore, date: Date) {
        if isVisible { close() } else { show(store: store, date: date) }
    }

    static let minSize = NSSize(width: 760, height: 480)

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let window = DayLogWindow(contentViewController: host)
        window.title = "当天日志"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.minSize = Self.minSize
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        if !window.setFrameUsingName(frameName) {
            window.setContentSize(NSSize(width: 1040, height: 700))
            window.center()
        }
        window.setFrameAutosaveName(frameName)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApplication.shared.isActive else { return }
            PreviousApp.restore(handoff: handoffWindow())
        }
    }
}
