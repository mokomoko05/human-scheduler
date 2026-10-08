import AppKit
import SwiftUI
import XCTest
import DayleafCore
@testable import Dayleaf

@MainActor
final class TagViewsTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    /// 把视图放进不可见的窗口里排版，返回它的实际大小。
    private func layout<V: View>(_ view: V, width: CGFloat, height: CGFloat = 800) -> NSSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        Self.keepAlive += [window, host]
        return host.fittingSize
    }

    func testFlowLayoutWrapsChipsOntoNewRows() {
        let chips = ["项目A", "项目B", "项目C", "项目D", "项目E", "项目F"]
        let wide = layout(FlowLayout { ForEach(chips, id: \.self) { TagChip(name: $0) } }, width: 600)
        let narrow = layout(FlowLayout { ForEach(chips, id: \.self) { TagChip(name: $0) } }, width: 120)
        XCTAssertGreaterThan(wide.height, 10)
        XCTAssertGreaterThan(narrow.height, wide.height * 2, "窄了就折成多行")
    }

    func testBatchTagViewRendersForSelectedLogs() throws {
        let store = makeStore()
        _ = try store.quickLog("甲", on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("乙", on: day, now: day.addingTimeInterval(2))
        let ids = Set(store.allLogs().map(\.log.id))
        store.updateLogTags(add: ["灵感"], forLogs: [try XCTUnwrap(ids.first)])
        let size = layout(LogBatchTagView(store: store, logIDs: ids), width: 380)
        XCTAssertGreaterThan(size.height, 100, "部分日志带有的标签也会列出来")
    }

    func testLinkPickerTagBarAndNotebookPageRender() throws {
        let store = makeStore()
        for title in ["读摘要 #论文", "看公式", "写周报"] { _ = store.addParsedTodo(title, on: day) }
        store.createTag("读书笔记")
        let picker = layout(LinkPickerView(store: store, current: nil, pick: { _ in }), width: 380)
        XCTAssertGreaterThan(picker.height, 150, "有候选时显示列表")
        for index in 0..<40 { _ = store.addParsedTodo("待办 \(index)", on: day) }
        let many = layout(LinkPickerView(store: store, current: nil, pick: { _ in }), width: 380)
        XCTAssertLessThan(many.height, 460, "待办很多时列表高度有上限，不会撑满屏幕")
        XCTAssertGreaterThan(store.linkCandidates().count, 40)
        var chosen: [String] = []
        let bar = layout(TagSelectionBar(store: store, selection: Binding(get: { chosen }, set: { chosen = $0 })), width: 460)
        XCTAssertGreaterThan(bar.height, 20)
        for tag in ["读书笔记", "论文"] {
            let notes = NotesView(store: store, initialTag: tag, reveal: { _ in }, openDay: { _ in })
            XCTAssertGreaterThan(layout(notes, width: 900).height, 100, "空标签和有内容的标签都能打开")
        }
    }

    func testPickerAndNotesViewRenderWithTags() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.addParsedTodo("读摘要 #论文", on: day))
        _ = store.addParsedTodo("看公式 #论文/方法 #阅读", on: day)
        _ = try store.quickLog("摘要读完了", taskID: a.id, on: day)

        let picker = layout(TagPickerView(store: store, task: a.task), width: 360)
        XCTAssertGreaterThan(picker.height, 100, "标签选择页有内容")

        for (selection, tag) in [(nil, "论文"), (a.id, nil)] as [(UUID?, String?)] {
            let notes = NotesView(store: store, initialSelection: selection, initialTag: tag, reveal: { _ in }, openDay: { _ in })
            let size = layout(notes, width: 900)
            XCTAssertGreaterThan(size.height, 100)
        }
    }
}
