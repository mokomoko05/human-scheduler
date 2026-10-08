import Foundation
import DayleafCore

/// 笔记窗口停在哪里：选中的任务或标签、搜索词、标签页按待办还是按日期看。
/// 每次变化都存进偏好，所以关掉窗口甚至退出应用再打开，都回到上次的位置，不用重新搜索。
@MainActor
final class NotesNavigation: ObservableObject {
    private let defaults: UserDefaults?
    private let prefix: String

    @Published var selection: UUID? { didSet { save() } }
    @Published var tagSelection: String? { didSet { save() } }
    @Published var query: String { didSet { save() } }
    @Published var chapterView: Bool { didSet { save() } }

    /// `defaults` 为 nil 时只在内存里（测试、一次性的视图）。
    init(defaults: UserDefaults? = nil, prefix: String = "notes.nav") {
        self.defaults = defaults
        self.prefix = prefix
        selection = defaults?.string(forKey: prefix + ".task").flatMap(UUID.init(uuidString:))
        tagSelection = defaults?.string(forKey: prefix + ".tag")
        query = defaults?.string(forKey: prefix + ".query") ?? ""
        chapterView = defaults?.object(forKey: prefix + ".chapters") as? Bool ?? true
    }

    private func save() {
        guard let defaults else { return }
        defaults.set(selection?.uuidString, forKey: prefix + ".task")
        defaults.set(tagSelection, forKey: prefix + ".tag")
        defaults.set(query, forKey: prefix + ".query")
        defaults.set(chapterView, forKey: prefix + ".chapters")
    }

    func open(task id: UUID) { tagSelection = nil; selection = id }
    func open(tag: String) { selection = nil; tagSelection = tag }

    /// 上次停留的任务被删除、或标签不存在了，就退回到最近有笔记的任务；停留的位置还有效就原样保留。
    func validate(in store: JournalStore) {
        if let tag = tagSelection, !store.allTags().contains(where: { $0.id == TagText.key(tag) }) { tagSelection = nil }
        if let id = selection, !store.noteTopics().contains(where: { $0.id == id }) { selection = nil }
        if selection == nil, tagSelection == nil { selection = store.noteTopics().first?.id }
    }
}
