import AppKit
import XCTest
import DayleafCore
@testable import Dayleaf

@MainActor
final class NotesWindowTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    func testNotesOpenInAResizableChildWindowThatIsReusedAndClosesWithItsParent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let parent = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        let controller = NotesWindowController()
        Self.keepAlive += [parent, controller]

        controller.show(store: store, taskID: nil, parent: parent, reveal: { _ in }, openDay: { _ in })
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.resizable), "笔记窗口可以调整大小")
        XCTAssertNil(parent.attachedSheet, "不再是 sheet")
        XCTAssertFalse(window.styleMask.contains(.closable), "没有关闭按钮")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertTrue(window.standardWindowButton(button)?.isHidden ?? true, "红绿灯都隐藏")
        }
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(parent.childWindows?.contains(window) == true, "作为子窗口，主窗口隐藏时一起走")
        XCTAssertTrue(WindowFade.family(of: parent).contains(window), "淡出时一起渐变")

        controller.show(store: store, taskID: nil, parent: parent, reveal: { _ in }, openDay: { _ in })
        XCTAssertTrue(controller.window === window, "再次打开复用同一个窗口")
        XCTAssertEqual(parent.childWindows?.filter { $0 === window }.count, 1)

        window.cancelOperation(nil)
        XCTAssertFalse(window.isVisible, "Esc 关闭")
        XCTAssertFalse(parent.childWindows?.contains(window) == true)
        controller.show(store: store, taskID: nil, parent: parent, reveal: { _ in }, openDay: { _ in })
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(parent.childWindows?.contains(window) == true, "关闭后再打开重新挂回主窗口")
        controller.close()
    }

    func testToggleOpensThenClosesAndKeepsSizeAcrossToggles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let controller = NotesWindowController()
        Self.keepAlive += [controller]
        let toggle = { controller.toggle(store: store, taskID: nil, parent: nil, reveal: { _ in }, openDay: { _ in }) }
        toggle()
        XCTAssertTrue(controller.isVisible, "第一次按下打开")
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 600))
        toggle()
        XCTAssertFalse(controller.isVisible, "再按一次关闭")
        toggle()
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(window.contentLayoutRect.width, 900, accuracy: 1, "重新打开时大小不变")
        controller.close()
    }
}
