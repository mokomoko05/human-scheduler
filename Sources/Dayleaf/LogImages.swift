import AppKit
import SwiftUI
import DayleafCore

struct ImagePreviewItem: Identifiable {
    let id = UUID()
    let names: [String]
    var index: Int
}

/// 缩略图方块；文件缺失时显示占位。
struct ImageThumb: View {
    let url: URL
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let image = ImageTools.thumbnail(url, maxPixel: Int(size * 3)) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo.badge.exclamationmark").font(.system(size: size * 0.35)).foregroundStyle(TerminalPalette.muted)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.16)))
    }
}

/// 完整显示一张图：按原始比例缩小到放得进框里，不裁剪。截取的论文插图通常不大，缩小后可以整张看清。
struct ImageFit: View {
    let url: URL
    var maxWidth: CGFloat = 320
    var maxHeight: CGFloat = 170

    var body: some View {
        if let image = ImageTools.thumbnail(url, maxPixel: Int(max(maxWidth, maxHeight) * 3)) {
            let size = ImageTools.fittedSize(pixels: image.size, maxWidth: maxWidth, maxHeight: maxHeight)
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.16)))
        } else {
            ImageThumb(url: url, size: 56)
        }
    }
}

/// 输入框上方：已粘贴、还没提交的图片。
struct PendingImagesStrip: View {
    let store: JournalStore
    let names: [String]
    let remove: (String) -> Void
    let preview: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    Button { preview(index) } label: { ImageThumb(url: store.imageURL(name)) }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) {
                            Button { remove(name) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                                    .foregroundStyle(Color.white, Color.black.opacity(0.7))
                            }
                            .buttonStyle(.plain).offset(x: 5, y: -5)
                            .help("移除这张图片").accessibilityLabel("移除图片")
                        }
                        .help("点击查看大图")
                        .accessibilityLabel("待发送图片 \(index + 1)")
                }
                Text("\(names.count) 张图片，回车随日志一起保存")
                    .font(.system(size: UIScale.pt(11))).foregroundStyle(TerminalPalette.muted)
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
        }
    }
}

/// 日志行展开后显示的缩略图。
struct LogImageGallery: View {
    let store: JournalStore
    let names: [String]
    let preview: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    Button { preview(index) } label: { ImageFit(url: store.imageURL(name), maxWidth: 360, maxHeight: 190) }
                        .buttonStyle(.plain)
                        .help("点击查看大图").accessibilityLabel("图片 \(index + 1) / \(names.count)，查看大图")
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.leading, 76)
    }
}

/// 大图预览：← → 切换，Esc 关闭，可在「预览」中打开或复制。
struct ImagePreviewSheet: View {
    let store: JournalStore
    @State var item: ImagePreviewItem
    @Environment(\.dismiss) private var dismiss

    private var url: URL { store.imageURL(item.names[item.index]) }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().padding(8)
                } else {
                    Label("找不到这张图片的文件", systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                Button { item.index = max(0, item.index - 1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: []).disabled(item.index == 0).accessibilityLabel("上一张")
                Text("\(item.index + 1) / \(item.names.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Button { item.index = min(item.names.count - 1, item.index + 1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: []).disabled(item.index >= item.names.count - 1).accessibilityLabel("下一张")
                Spacer()
                Button("复制图片") {
                    if let image = NSImage(contentsOf: url) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                }
                Button("在「预览」中打开") { NSWorkspace.shared.open(url) }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16).frame(minWidth: 720, minHeight: 520)
    }
}

/// 选择要筛选的任务：当天清单里的任务，以及所有被日志关联过的任务。
struct LogFilterPopover: View {
    @ObservedObject var store: JournalStore
    let date: Date
    @Binding var selection: Set<UUID>

    var body: some View {
        let summaries = store.logTaskSummaries(on: date)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("按任务筛选日志").font(.headline)
                Spacer()
                Button("清除") { selection = [] }.disabled(selection.isEmpty)
            }
            Text("勾选后，日志区会跨日期只显示这些任务相关的记录。")
                .font(.caption).foregroundStyle(.secondary)
            if summaries.isEmpty {
                Text("还没有任务。先添加待办，再用 /link #1 把日志记到它名下。").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(summaries) { task in
                            Toggle(isOn: Binding(get: { selection.contains(task.id) },
                                                 set: { if $0 { selection.insert(task.id) } else { selection.remove(task.id) } })) {
                                HStack(spacing: 6) {
                                    if let number = task.number {
                                        Text("#\(number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    Text(task.title).lineLimit(1)
                                    if task.deleted { Text("（已删除）").font(.caption).foregroundStyle(.secondary) }
                                    Spacer(minLength: 8)
                                    Text("\(task.count) 条").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox).padding(.vertical, 3)
                        }
                    }
                }.frame(maxHeight: 280)
            }
        }
        .padding(16).frame(width: 340)
    }
}
