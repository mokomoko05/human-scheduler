import AppKit
import SwiftUI
import DayleafCore

private final class NotesWindow: QuietWindow {
    /// 没有文字框处理 Esc 时关闭窗口，和原来 sheet 里的「关闭」一致。
    override func cancelOperation(_ sender: Any?) { close() }
}

/// 笔记窗口：可以自由调整大小的独立窗口。它和主窗口、终端、快速记录窗口互不依赖：
/// 各自用自己的快捷键开关，主窗口收起（⌃⌥D）时笔记照常留着；大小和位置会被记住。
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    static let frameName = "DayleafNotesWindow"
    /// 应用里唯一的笔记窗口：界面和全局快捷键共用同一个。
    static let shared = NotesWindowController()
    private(set) var window: NSWindow?
    /// 上次停留的位置，存进偏好；窗口关闭后视图和里面没发送的草稿也留着。
    let nav: NotesNavigation

    init(nav: NotesNavigation? = nil) {
        self.nav = nav ?? NotesNavigation(defaults: .standard)
        super.init()
    }
    /// 笔记关闭后，Scheduler 别的窗口（主窗口、终端）如果还开着，焦点交给它；由 AppDelegate 设置。
    var handoffWindow: () -> NSWindow? = { nil }

    var isVisible: Bool { window?.isVisible == true }

    /// 打开笔记窗口。指定 `taskID` 或 `tag` 就跳到那里；都不指定则保持上次关闭时的样子。已经开着就复用同一个窗口。
    func show(store: JournalStore, taskID: UUID?, tag: String? = nil,
              reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        let window = self.window ?? makeWindow()
        self.window = window
        let view = NotesView(store: store, initialSelection: taskID, initialTag: tag, nav: nav,
                             close: { [weak self] in self?.close() },
                             reveal: reveal, openDay: openDay)
        // 不再给视图换新的 id：保持同一个视图，里面的草稿、编辑状态和滚动位置都留着。
        if let host = window.contentViewController as? NSHostingController<AnyView> {
            host.rootView = AnyView(view)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    /// 快捷键（默认 ⌃N）：开着就关，关着就开。
    func toggle(store: JournalStore, taskID: UUID?,
                reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        if isVisible { close() } else { show(store: store, taskID: taskID, reveal: reveal, openDay: openDay) }
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let window = NotesWindow(contentViewController: host)
        window.title = "笔记"
        // 没有红绿灯：用 Esc 或快捷键关闭。标题栏透明，整个窗口背景都可以拖动。
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 1000, height: 680))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    /// 关闭后：Scheduler 还有别的窗口开着就交给它，否则回到刚才在用的应用（和主窗口、终端的收起一致）。
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApplication.shared.isActive else { return }
            PreviousApp.restore(handoff: handoffWindow())
        }
    }
}
