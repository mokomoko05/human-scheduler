import SwiftUI
import DayleafCore

/// 自动换行的横向排列：标签一行放不下就折到下一行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (positions, CGSize(width: widest, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(subviews, width: bounds.width)
        for (view, point) in zip(subviews, laid.positions) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// 圆角矩形标签：`highlighted` 表示选中。
struct TagChip: View {
    let name: String
    var highlighted = false
    var size: CGFloat = 12

    var body: some View {
        Text("#" + name)
            .font(.system(size: UIScale.pt(size), weight: highlighted ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(highlighted ? Color.white : Palette.ink)
            .background(highlighted ? Palette.accent : Palette.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(highlighted ? Color.clear : Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// 待办行里的一排标签（点一下打开这个标签名下的笔记）。
struct TaskTagLine: View {
    let tags: [String]
    var fontSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Button { NotificationCenter.default.post(name: .dayleafOpenTag, object: tag) } label: {
                    Text("#" + tag).font(.system(size: UIScale.pt(fontSize))).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Palette.soft, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
                .help("查看 #\(tag) 名下的笔记")
            }
        }
    }
}

/// 给一个待办选标签：已有的标签是圆角矩形，选中的高亮，点一下切换；也可以输入新标签。
struct TagPickerView: View {
    @ObservedObject var store: JournalStore
    let task: Todo
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String]
    @State private var added: [String] = []
    @State private var draft = ""
    @State private var message: String?
    @FocusState private var typing: Bool

    init(store: JournalStore, task: Todo) {
        self.store = store
        self.task = task
        _selected = State(initialValue: task.tags)
    }

    /// 可选的标签：库里已有的（最近用过的在前）、这个待办自己的，以及刚输入的新标签。
    private var choices: [String] {
        TagText.merge(TagText.merge(task.tags, store.allTags().map(\.name)), added)
    }

    private func isSelected(_ tag: String) -> Bool { selected.contains { TagText.key($0) == TagText.key(tag) } }

    private func toggle(_ tag: String) {
        if isSelected(tag) { selected.removeAll { TagText.key($0) == TagText.key(tag) } } else { selected.append(tag) }
        message = nil
    }

    private func commitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let tags = TagText.parseList(text)
        guard !tags.isEmpty else {
            message = "标签不能含空格，也不能是纯数字（#3 表示任务编号）"
            return
        }
        for tag in tags {
            // 和已有标签只差大小写时，沿用已有写法。
            let existing = choices.first { TagText.key($0) == TagText.key(tag) } ?? tag
            if !choices.contains(existing) { added.append(existing) }
            if !isSelected(existing) { selected.append(existing) }
        }
        draft = ""
        message = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("标签").font(.headline)
                Text(String(TaskText.rendered(task.title).characters)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if choices.isEmpty {
                Text("还没有标签。在下面输入一个，回车添加。").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(choices, id: \.self) { tag in
                            Button { toggle(tag) } label: { TagChip(name: tag, highlighted: isSelected(tag)) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("#\(tag)").accessibilityValue(isSelected(tag) ? "已选中" : "未选中")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").foregroundStyle(Palette.muted)
                    TextField("新标签，回车添加（可用 / 分层，例如 项目/子项）", text: $draft)
                        .textFieldStyle(.plain).focused($typing).onSubmit(commitDraft)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            HStack {
                Text(selected.isEmpty ? "未选标签" : "已选 \(selected.count) 个").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    commitDraft()
                    store.setTags(task.id, selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(store.isReadOnly)
            }
        }
        .padding(18).frame(width: 360)
        .onAppear { typing = false }
    }
}
