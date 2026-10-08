import AppKit
import SwiftUI
import DayleafCore

private final class NotesWindow: QuietWindow {
    /// 没有文字框处理 Esc 时关闭窗口，和原来 sheet 里的「关闭」一致。
    override func cancelOperation(_ sender: Any?) { close() }
}

/// 笔记窗口：可以自由调整大小的独立窗口，不再是主窗口上的 sheet。
/// 它是主窗口的子窗口，所以主窗口隐藏（⌃⌥D）、淡出时会一起走；大小和位置会被记住。
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    static let frameName = "DayleafNotesWindow"
    private(set) var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    /// 打开笔记窗口并定位到 `taskID`；已经开着就复用同一个窗口。
    func show(store: JournalStore, taskID: UUID?, tag: String? = nil, parent: NSWindow?,
              reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        let window = self.window ?? makeWindow()
        self.window = window
        let view = NotesView(store: store, initialSelection: taskID, initialTag: tag,
                             close: { [weak self] in self?.close() },
                             reveal: reveal, openDay: openDay)
        // 每次换一个新的 id，让视图按新的任务重新初始化选中项。
        if let host = window.contentViewController as? NSHostingController<AnyView> {
            host.rootView = AnyView(view.id(UUID()))
        }
        if !window.isVisible, let parent, parent.isVisible, window.parent == nil { parent.addChildWindow(window, ordered: .above) }
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    /// 快捷键（默认 ⌃N）：开着就关，关着就开。
    func toggle(store: JournalStore, taskID: UUID?, parent: NSWindow?,
                reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        if isVisible { close() } else { show(store: store, taskID: taskID, parent: parent, reveal: reveal, openDay: openDay) }
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

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.parent?.removeChildWindow(window)
    }
}
