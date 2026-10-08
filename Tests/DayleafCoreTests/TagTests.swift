import XCTest
@testable import DayleafCore

@MainActor
final class TagTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testNormalizeRejectsNumbersAndWhitespace() {
        XCTAssertEqual(TagText.normalize("#项目A"), "项目A")
        XCTAssertEqual(TagText.normalize("  ##读书,"), "读书")
        XCTAssertNil(TagText.normalize("#3"), "纯数字是任务编号")
        XCTAssertNil(TagText.normalize("a b"))
        XCTAssertNil(TagText.normalize("#"))
        XCTAssertNil(TagText.normalize(String(repeating: "长", count: 41)))
        XCTAssertEqual(TagText.parseList("#a, B  b,#A 项目/子项"), ["a", "B", "项目/子项"], "不区分大小写去重")
    }

    func testExtractOnlyTakesTagsAtWordStart() {
        XCTAssertEqual(TagText.extract(from: "写报告 #项目A #紧急").tags, ["项目A", "紧急"])
        XCTAssertEqual(TagText.extract(from: "写报告 #项目A #紧急").title, "写报告")
        XCTAssertEqual(TagText.extract(from: "修复 C# 问题").tags, [], "C# 里的 # 不是标签")
        XCTAssertEqual(TagText.extract(from: "看 #3 的进展").tags, [], "#3 是任务编号")
        XCTAssertEqual(TagText.extract(from: "读 [文档](https://example.com/a#intro) #阅读").tags, ["阅读"], "链接里的 # 不算")
        XCTAssertTrue(TagText.extract(from: "读 [文档](https://example.com/a#intro) #阅读").title.contains("a#intro"))
        let only = TagText.extract(from: "#项目A")
        XCTAssertEqual(only.title, "#项目A", "整行只有标签时保留原文，不生成空标题")
        XCTAssertEqual(only.tags, [])
    }

    func testQuickAddTakesTagsBeforeDates() {
        let now = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        let parsed = QuickAdd.parse("#周五 明天 15:00 开会 #项目A", now: now)
        XCTAssertEqual(parsed.tags, ["周五", "项目A"], "#周五 是标签，不是日期")
        XCTAssertEqual(parsed.title, "开会")
        XCTAssertEqual(parsed.hour, 15)
        XCTAssertEqual(QuickAdd.parse("开会", now: now).tags, [])
        XCTAssertEqual(QuickAdd.parse("#项目A", now: now).tags, [], "只有标签时按原文当标题")
    }

    func testNewTodoCarriesTagsAndRenameMovesThemOutOfTheTitle() throws {
        let store = makeStore()
        let added = try XCTUnwrap(store.addParsedTodo("整理方法部分 #论文", on: day))
        XCTAssertEqual(added.task.title, "整理方法部分")
        XCTAssertEqual(added.task.tags, ["论文"])
        store.renameTodo(added.id, title: "整理方法部分 #论文 #EuroSys", on: added.date)
        let renamed = try XCTUnwrap(store.locate(added.id))
        XCTAssertEqual(renamed.task.title, "整理方法部分")
        XCTAssertEqual(renamed.task.tags, ["论文", "EuroSys"])
    }

    func testTagsSurviveSaveAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let added = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        store.save()
        let reopened = JournalStore(directory: directory)
        XCTAssertEqual(reopened.locate(added.id)?.task.tags, ["论文"])
    }

    func testOldDocumentsWithoutTagsStillLoad() throws {
        let json = #"{"id":"6B0E6D5B-6C47-4B58-9D5B-0A7C6E8F1A11","title":"旧任务","completed":false}"#
        let todo = try JSONDecoder().decode(Todo.self, from: Data(json.utf8))
        XCTAssertEqual(todo.tags, [])
    }

    func testSetTagsIsUndoableAndNormalized() throws {
        let store = makeStore()
        let added = try XCTUnwrap(store.addParsedTodo("读论文", on: day))
        store.setTags(added.id, ["#论文", "论文", "a b", "3", "阅读"])
        XCTAssertEqual(store.locate(added.id)?.task.tags, ["论文", "阅读"])
        store.undoManager.undo()
        XCTAssertEqual(store.locate(added.id)?.task.tags, [])
    }

    func testTaggedNotesGatherSmallTodosUnderOneTopic() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.addParsedTodo("读摘要 #论文", on: day))
        let b = try XCTUnwrap(store.addParsedTodo("看公式 #论文/方法", on: day))
        let c = try XCTUnwrap(store.addParsedTodo("买菜 #生活", on: day))
        _ = try store.quickLog("摘要读完了", taskID: a.id, on: day, now: day.addingTimeInterval(30))
        _ = try store.quickLog("公式推到一半", taskID: b.id, on: day, now: day.addingTimeInterval(60))
        _ = try store.quickLog("买了西红柿", taskID: c.id, on: day, now: day.addingTimeInterval(90))
        XCTAssertNotNil(store.addFocusLog("▶ 开始专注", taskID: a.id, now: day.addingTimeInterval(120)))

        XCTAssertEqual(store.notes(forTag: "论文").map(\.log.text), ["摘要读完了", "公式推到一半"], "子标签的笔记一起汇总，不含专注记录")
        XCTAssertEqual(store.notes(forTag: "论文/方法").map(\.log.text), ["公式推到一半"])
        XCTAssertEqual(store.notes(forTag: "论").count, 0, "不是前缀匹配")
        XCTAssertEqual(store.tasks(taggedWith: "LUNWEN").count, 0)
        XCTAssertEqual(store.tasks(taggedWith: "论文").count, 2)

        let summaries = store.allTags()
        XCTAssertEqual(Set(summaries.map(\.name)), ["论文", "论文/方法", "生活"])
        let paper = try XCTUnwrap(summaries.first { $0.name == "论文" })
        XCTAssertEqual(paper.taskCount, 2, "含子标签")
        XCTAssertEqual(paper.noteCount, 2)
        XCTAssertEqual(summaries.first { $0.name == "论文/方法" }?.taskCount, 1)
        _ = store.addParsedTodo("另一个 #读书/小说", on: day)
        XCTAssertTrue(store.allTags().contains { $0.name == "读书" }, "只用了子标签时，上级标签也会出现")
    }

    func testSearchMatchesTagsAndHashQueryIsExact() throws {
        let store = makeStore()
        _ = store.addParsedTodo("写报告 #项目A", on: day)
        _ = store.addParsedTodo("项目A 的周会", on: day)
        XCTAssertEqual(store.tasks(matching: "#项目A").map(\.task.title), ["写报告"], "#标签 只找带标签的")
        XCTAssertEqual(store.tasks(matching: "项目A").count, 2, "普通词标题和标签都匹配")
        XCTAssertEqual(store.tasks(matching: "#项目a").count, 1, "不区分大小写")
    }

    func testRepeatingTaskKeepsTagsOnNextOccurrence() throws {
        let store = makeStore()
        let added = try XCTUnwrap(store.addParsedTodo("每天 晨读 #阅读", on: day, now: day))
        store.toggleTodo(added.id, on: added.date, now: day)
        XCTAssertEqual(store.tasks(taggedWith: "阅读").count, 2)
    }
}

@MainActor
final class LogTagTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testLogsWrittenWhileFocusingCarryTheTaskAndItsTags() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("看公式 #论文 #方法", on: day))
        store.setFocusTask(task.id)
        _ = try store.quickLog("推到第三步", on: day)
        let log = try XCTUnwrap(store.allLogs().last?.log)
        XCTAssertEqual(log.taskID, task.id)
        XCTAssertEqual(log.taskNumber, task.task.number)
        XCTAssertEqual(log.taskTags, ["论文", "方法"], "日志里记着待办当时的标签")
        let focusLog = try XCTUnwrap(store.addFocusLog("▶ 开始专注", taskID: task.id, now: day.addingTimeInterval(60)))
        let stored = try XCTUnwrap(store.allLogs(includeFocus: true).first { $0.id == focusLog }?.log)
        XCTAssertEqual(stored.taskTags, ["论文", "方法"], "专注开始、结束记录也带标签")
        XCTAssertEqual(store.logs(forTag: "方法").count, 2)
        XCTAssertEqual(store.notes(forTag: "方法").count, 1, "笔记不含专注记录")
    }

    func testCommitLogAndRelinkRecordTags() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        store.setLogDraft("#\(task.task.number ?? 0) 第一章读完", on: day)
        _ = try store.commitLog(on: day)
        XCTAssertEqual(store.allLogs().last?.log.taskTags, ["论文"])
        _ = try store.quickLog("无关联", on: day)
        let loose = try XCTUnwrap(store.allLogs().last?.log)
        XCTAssertTrue(loose.taskTags.isEmpty)
        store.setLogTask(task.id, forLog: loose.id, on: day)
        XCTAssertEqual(store.allLogs().last?.log.taskTags, ["论文"], "补关联时记下标签")
        store.setLogTask(nil, forLog: loose.id, on: day)
        XCTAssertTrue(store.allLogs().last?.log.taskTags.isEmpty == true)
    }

    func testRetaggingTheTaskMovesItsNotesButDeletedTaskKeepsTheSnapshot() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        _ = try store.quickLog("笔记一", taskID: task.id, on: day)
        store.setTags(task.id, ["阅读"])
        XCTAssertEqual(store.notes(forTag: "阅读").count, 1, "改标签后，旧笔记跟着待办走")
        XCTAssertEqual(store.notes(forTag: "论文").count, 0)
        store.deleteTodo(task.id, on: task.date)
        XCTAssertEqual(store.notes(forTag: "论文").count, 1, "待办删除后，用日志里记下的标签（当时是「论文」）")
        XCTAssertEqual(store.allTags().first?.name, "论文")
        XCTAssertEqual(store.allTags().first?.taskCount, 0)
    }

    func testOldLogsWithoutTagsStillDecodeAndEncodeUnchanged() throws {
        let log = DailyLogEntry(createdAt: day, kind: .note, text: "旧日志")
        let data = try JSONEncoder().encode(log)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("taskTags"), "没有标签时不写新字段")
        XCTAssertEqual(try JSONDecoder().decode(DailyLogEntry.self, from: data).taskTags, [])
    }
}

@MainActor
final class BatchLogTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    private func logIDs(_ store: JournalStore) -> [UUID] { store.allLogs().map(\.log.id) }

    func testBatchTagsAddRemoveAreOneUndoAndWorkWithoutATask() throws {
        let store = makeStore()
        _ = try store.quickLog("甲", on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("乙", on: day, now: day.addingTimeInterval(2))
        _ = try store.quickLog("丙", on: day, now: day.addingTimeInterval(3))
        let ids = logIDs(store)
        XCTAssertEqual(store.updateLogTags(add: ["#灵感", "项目/A", "a b"], forLogs: Set(ids.prefix(2))), 2, "非法标签被忽略")
        XCTAssertEqual(store.allLogs().map(\.log.tags), [["灵感", "项目/A"], ["灵感", "项目/A"], []])
        XCTAssertEqual(store.notes(forTag: "灵感").map(\.log.text), ["甲", "乙"], "没有关联待办的日志也能按标签汇总")
        XCTAssertEqual(store.notes(forTag: "项目").count, 2, "含子标签")
        XCTAssertEqual(store.updateLogTags(add: ["灵感"], forLogs: Set(ids.prefix(2))), 0, "已有的不算改动")
        XCTAssertEqual(store.updateLogTags(remove: ["灵感"], forLogs: [ids[0]]), 1)
        XCTAssertEqual(store.allLogs().first?.log.tags, ["项目/A"])
        store.undoManager.undo()
        XCTAssertEqual(store.allLogs().first?.log.tags, ["灵感", "项目/A"], "撤销一次还原整批")
        store.undoManager.undo()
        XCTAssertTrue(store.allLogs().allSatisfy { $0.log.tags.isEmpty })
    }

    func testLogTagsAddToTheLinkedTaskTagsAndShowInSummaries() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        _ = try store.quickLog("笔记", taskID: task.id, on: day)
        let id = try XCTUnwrap(store.allLogs().first?.log.id)
        store.updateLogTags(add: ["待整理"], forLogs: [id])
        XCTAssertEqual(store.tags(of: try XCTUnwrap(store.allLogs().first?.log)), ["论文", "待整理"])
        XCTAssertEqual(store.notes(forTag: "待整理").count, 1)
        XCTAssertEqual(store.allTags().first { $0.name == "待整理" }?.noteCount, 1)
        XCTAssertEqual(store.allTags().first { $0.name == "待整理" }?.taskCount, 0, "只在日志上，不算待办")
    }

    func testBatchLinkSetsTaskTitleNumberAndTagsAndUnlinks() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        let b = try XCTUnwrap(store.addParsedTodo("写周报", on: day))
        _ = try store.quickLog("甲", taskID: b.id, on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("乙", on: day, now: day.addingTimeInterval(2))
        _ = try store.quickLog("丙", on: day, now: day.addingTimeInterval(3))
        let ids = logIDs(store)
        XCTAssertEqual(store.setLogTask(a.id, forLogs: Set(ids)), 3)
        for log in store.allLogs().map(\.log) {
            XCTAssertEqual(log.taskID, a.id)
            XCTAssertEqual(log.taskNumber, a.task.number)
            XCTAssertEqual(log.taskTags, ["论文"])
            XCTAssertEqual(log.taskTitle, "读论文")
        }
        XCTAssertEqual(store.notes(for: a.id).count, 3)
        XCTAssertEqual(store.setLogTask(a.id, forLogs: Set(ids)), 0, "已经关联的不重复改动")
        store.undoManager.undo()
        XCTAssertEqual(store.allLogs().map(\.log.taskID), [b.id, nil, nil], "撤销一次还原整批")
        XCTAssertEqual(store.setLogTask(nil, forLogs: Set(ids)), 1)
        XCTAssertTrue(store.allLogs().allSatisfy { $0.log.taskID == nil && $0.log.taskNumber == nil })
        XCTAssertEqual(store.setLogTask(UUID(), forLogs: Set(ids)), 0, "不存在的待办不改动")
    }

    func testOldLogsWithoutOwnTagsDecodeAndEncodeUnchanged() throws {
        let log = DailyLogEntry(createdAt: day, kind: .note, text: "旧")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(log), as: UTF8.self).contains("\"tags\""), "没有标签不写新字段")
        XCTAssertEqual(try JSONDecoder().decode(DailyLogEntry.self, from: try JSONEncoder().encode(log)).tags, [])
    }
}
