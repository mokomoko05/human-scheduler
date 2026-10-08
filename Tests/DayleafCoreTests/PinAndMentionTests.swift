import XCTest
@testable import DayleafCore

@MainActor
final class PinAndMentionTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
    private var directory: URL!

    private func makeStore(titles: [String] = ["读论文 #论文", "写周报", "整理发票", "复习 英语"]) -> JournalStore {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { [directory] in if let directory { try? FileManager.default.removeItem(at: directory) } }
        let store = JournalStore(directory: directory)
        for title in titles { _ = store.addParsedTodo(title, on: day) }
        return store
    }

    private func id(_ store: JournalStore, _ number: Int) -> UUID { store.locate(number: number)!.id }

    // MARK: - 固定关联

    func testPinnedTaskIsTheDefaultLinkButFocusAndExplicitWin() throws {
        let store = makeStore()
        XCTAssertTrue(store.pinTask(id(store, 2)))
        _ = try store.quickLog("固定期间的日志", on: day, now: day.addingTimeInterval(1))
        XCTAssertEqual(store.allLogs().last?.log.taskNumber, 2, "没指定、没专注时，记到固定的待办")

        store.setFocusTask(id(store, 3))
        _ = try store.quickLog("专注期间", on: day, now: day.addingTimeInterval(2))
        XCTAssertEqual(store.allLogs().last?.log.taskNumber, 3, "专注中的优先于固定的")
        store.setFocusTask(nil)

        _ = try store.quickLog("显式", taskID: id(store, 1), on: day, now: day.addingTimeInterval(3))
        XCTAssertEqual(store.allLogs().last?.log.taskNumber, 1, "明确指定的最优先")

        _ = try store.quickLog("不关联", linkDefault: false, on: day, now: day.addingTimeInterval(4))
        XCTAssertNil(store.allLogs().last?.log.taskID, "明确不关联就不关联")
        XCTAssertEqual(store.pinnedTask?.task.number, 2, "不关联不会取消固定")
    }

    func testPinSurvivesReloadAndClearsWhenTaskCompletesOrIsDeleted() throws {
        let store = makeStore()
        store.pinTask(id(store, 2))
        XCTAssertEqual(JournalStore(directory: directory).pinnedTask?.task.number, 2, "固定写进数据文件，重启后还在")

        store.toggleTodo(id(store, 2), on: day)
        XCTAssertNil(store.pinnedTask, "完成后固定自动取消")
        XCTAssertNil(store.pinnedTaskID)
        store.toggleTodo(id(store, 2), on: day)
        XCTAssertNil(store.pinnedTask, "撤销完成也不会悄悄恢复固定")

        XCTAssertFalse(store.pinTask(UUID()), "不存在的待办不能固定")
        store.toggleTodo(id(store, 3), on: day)
        XCTAssertFalse(store.pinTask(id(store, 3)), "已完成的待办不能固定")

        store.pinTask(id(store, 4))
        store.deleteTodo(id(store, 4), on: store.locate(number: 4)!.date)
        XCTAssertNil(store.pinnedTask)
        XCTAssertTrue(store.pinTask(nil))
    }

    func testDayLogCommitFallsBackToPinnedToo() throws {
        let store = makeStore()
        store.pinTask(id(store, 2))
        store.setLogDraft("日志窗口里写的", on: day)
        _ = try store.commitLog(on: day)
        XCTAssertEqual(store.allLogs().last?.log.taskNumber, 2)
        store.setLogDraft("#1 明确指定", on: day)
        _ = try store.commitLog(on: day)
        XCTAssertEqual(store.allLogs().last?.log.taskNumber, 1, "正文里的 #N 优先于固定")
    }

    // MARK: - 快速日志里的 #N

    func testQuickLogUnderstandsLeadingTaskReference() throws {
        let store = makeStore()
        _ = try store.quickLog("#2 周报写了一半", on: day, now: day.addingTimeInterval(1))
        var last = store.allLogs().last!.log
        XCTAssertEqual(last.taskNumber, 2)
        XCTAssertEqual(last.text, "周报写了一半", "开头的 #N 变成关联，不留在正文里")

        _ = try store.quickLog("#2", on: day, now: day.addingTimeInterval(2))
        last = store.allLogs().last!.log
        XCTAssertEqual(last.text, "#2", "只有 #N 没有内容时当作普通文字")
        XCTAssertNil(last.taskID)

        _ = try store.quickLog("#99 不存在的编号", on: day, now: day.addingTimeInterval(3))
        last = store.allLogs().last!.log
        XCTAssertEqual(last.text, "#99 不存在的编号")
        XCTAssertNil(last.taskID)

        _ = try store.quickLog("#2 显式的优先", taskID: id(store, 1), on: day, now: day.addingTimeInterval(4))
        last = store.allLogs().last!.log
        XCTAssertEqual(last.taskNumber, 1, "明确传入的任务优先于正文里的 #N")
        XCTAssertEqual(last.text, "#2 显式的优先")
    }

    func testQuickLogEntryReportsWhereTheLogLanded() throws {
        let store = makeStore()
        store.pinTask(id(store, 4))
        var result = try store.quickLogEntry("甲", on: day, now: day.addingTimeInterval(1))
        XCTAssertEqual(result.entry?.taskNumber, 4)
        result = try store.quickLogEntry("乙", linkDefault: false, on: day, now: day.addingTimeInterval(2))
        XCTAssertNil(result.entry?.taskID)
        let command = try store.quickLogEntry("/help", on: day)
        XCTAssertNil(command.entry, "不是普通记录就没有日志")
    }

    // MARK: - 智能候选

    func testCandidatesMatchPinyinInitialsAndMissingCharacters() {
        let store = makeStore()
        func numbers(_ query: String) -> [Int] { store.linkCandidates(query: query).compactMap(\.task.number) }
        XCTAssertEqual(numbers("dlw"), [1], "拼音首字母")
        XCTAssertEqual(numbers("lunwen"), [1], "全拼")
        XCTAssertEqual(numbers("DLW"), [1], "不分大小写")
        XCTAssertEqual(numbers("zbz"), [], "不相干的首字母没有结果")
        XCTAssertEqual(numbers("zhoubao"), [2])
        XCTAssertEqual(numbers("读文"), [1], "漏字也能找到")
        XCTAssertEqual(numbers("英语"), [4])
        XCTAssertEqual(numbers("fx"), [4], "复习的首字母 fx 对应「复习」")
        XCTAssertTrue(numbers("").count == 4)
    }

    func testCandidatesPreferStrongMatchesAndNumberExact() {
        let store = makeStore(titles: ["周报模板", "写周报", "报销", "10 号结算"])
        func numbers(_ query: String) -> [Int] { store.linkCandidates(query: query).compactMap(\.task.number) }
        XCTAssertEqual(numbers("周报").first, 1, "开头匹配排在包含之前")
        XCTAssertEqual(numbers("#4").first, 4, "编号精确命中最前")
        XCTAssertEqual(numbers("1").first, 1)
        XCTAssertEqual(numbers("10").first, 4, "标题里的 10 也算，但编号 10 不存在，不抢第一")
    }

    func testCandidatesRankFocusPinnedContextRecentInThatOrder() throws {
        let store = makeStore(titles: ["甲 #论文", "乙 #读书", "丙 #论文/方法", "丁", "戊"])
        _ = try store.quickLog("x", taskID: id(store, 5), on: day, now: day.addingTimeInterval(1))
        store.setFocusTask(id(store, 4))
        store.pinTask(id(store, 2))
        func numbers(_ context: [String]) -> [Int] { store.linkCandidates(contextTags: context).compactMap(\.task.number) }
        XCTAssertEqual(numbers([]), [4, 2, 5, 1, 3], "专注 → 固定 → 最近 → 其余按清单顺序")
        XCTAssertEqual(numbers(["论文"]), [4, 2, 1, 3, 5], "写在 #论文 下时，带这个标签（含子标签）的排在最近之前")
    }

    func testFuzzyMatchesComeAfterLiteralOnes() {
        let store = makeStore(titles: ["读论文", "读一篇关于论述的文章", "文论"])
        let order = store.linkCandidates(query: "读论文").compactMap(\.task.number)
        XCTAssertEqual(order.first, 1)
        let fuzzy = store.linkCandidates(query: "读文").compactMap(\.task.number)
        XCTAssertEqual(Set(fuzzy), [1, 2], "读…文 按顺序出现的都算")
        XCTAssertFalse(fuzzy.contains(3), "顺序不对不算")
    }
}
