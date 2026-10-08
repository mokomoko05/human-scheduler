import AppKit
import XCTest
import DayleafCore
@testable import Dayleaf

@MainActor
final class NotesNavigationTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func defaults() -> UserDefaults {
        let suite = "notes-nav-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
        }
        return defaults
    }

    private func makeStore() throws -> (JournalStore, ScheduledTask, ScheduledTask) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let a = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        let b = try XCTUnwrap(store.addParsedTodo("写周报", on: day))
        _ = try store.quickLog("甲", taskID: a.id, on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("乙", taskID: b.id, on: day, now: day.addingTimeInterval(2))
        return (store, a, b)
    }

    func testPositionSurvivesAFreshLaunch() throws {
        let defaults = defaults()
        let (_, a, _) = try makeStore()
        let first = NotesNavigation(defaults: defaults)
        first.open(task: a.id)
        first.query = "论文"
        first.chapterView = false
        let second = NotesNavigation(defaults: defaults)
        XCTAssertEqual(second.selection, a.id, "重启后还在上次的任务")
        XCTAssertEqual(second.query, "论文", "搜索词也在，不用重新搜")
        XCTAssertFalse(second.chapterView)
        first.open(tag: "论文")
        let third = NotesNavigation(defaults: defaults)
        XCTAssertNil(third.selection)
        XCTAssertEqual(third.tagSelection, "论文")
        XCTAssertTrue(NotesNavigation(defaults: nil).chapterView, "第一次用，默认按待办看")
    }

    func testValidateKeepsAValidPositionAndFallsBackWhenItIsGone() throws {
        let (store, a, b) = try makeStore()
        let nav = NotesNavigation()
        nav.open(task: b.id)
        nav.validate(in: store)
        XCTAssertEqual(nav.selection, b.id, "位置有效就原样保留，不跳到别处")
        nav.open(task: UUID())
        nav.validate(in: store)
        XCTAssertEqual(nav.selection, store.noteTopics().first?.id, "任务没了就退回最近有笔记的")
        nav.open(tag: "论文")
        nav.validate(in: store)
        XCTAssertEqual(nav.tagSelection, "论文")
        nav.open(tag: "已经不存在的标签")
        nav.validate(in: store)
        XCTAssertNil(nav.tagSelection)
        XCTAssertNotNil(nav.selection)
        _ = a
    }

    func testReopeningRestoresWhereYouLeftAndAnExplicitTargetOverridesIt() throws {
        let (store, a, b) = try makeStore()
        let nav = NotesNavigation()
        let controller = NotesWindowController(nav: nav)
        Self.keepAlive += [controller]
        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        nav.open(task: b.id)
        nav.query = "周报"
        let window = try XCTUnwrap(controller.window)
        controller.close()
        XCTAssertFalse(controller.isVisible)

        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(nav.selection, b.id, "再打开还是关闭时看的那个任务")
        XCTAssertEqual(nav.query, "周报", "搜索词还在")

        controller.close()
        controller.show(store: store, taskID: a.id, reveal: { _ in }, openDay: { _ in })
        XCTAssertEqual(nav.selection, a.id, "明确指定任务时才跳过去")
        controller.close()
        controller.show(store: store, taskID: nil, tag: "论文", reveal: { _ in }, openDay: { _ in })
        XCTAssertEqual(nav.tagSelection, "论文")
        XCTAssertNil(nav.selection)
        controller.close()
    }
}
