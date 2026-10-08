import AppKit
import SwiftUI
import DayleafCore

struct TaskInput: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Binding var text: String
    @Binding var focused: Bool
    var placeholder = ""
    var fontSize: CGFloat = 13
    let submit: () -> Void
    var cancel: () -> Void = {}
    var previous: () -> Void = {}
    var monospaced = false
    var historyUp: (() -> Void)?
    var historyDown: (() -> Void)?
    var complete: (() -> Void)?
    /// 设置后，粘贴图片会交给它处理（文字照常粘贴）。
    var onPasteImages: (([Data]) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = TaskTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.onAttach = { [weak field, weak coordinator = context.coordinator] in
            if let field { coordinator?.requestFocus(field) }
        }
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        field.placeholderString = placeholder
        field.font = monospaced ? .monospacedSystemFont(ofSize: UIScale.pt(fontSize), weight: .regular) : .systemFont(ofSize: UIScale.pt(fontSize))
        field.textColor = .labelColor
        field.isEditable = enabled
        field.isSelectable = true
        (field as? TaskTextField)?.onPasteImages = onPasteImages
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
        let wantsFocus = focused && enabled
        if wantsFocus, !context.coordinator.focusRequested { context.coordinator.requestFocus(field) }
        context.coordinator.focusRequested = wantsFocus
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TaskInput
        var focusRequested = false
        init(_ parent: TaskInput) { self.parent = parent }
        func requestFocus(_ field: NSTextField) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, field.isEditable, self.parent.focused,
                      field.currentEditor() == nil, field.window?.isKeyWindow == true,
                      field.window?.attachedSheet == nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) {
            focusRequested = false
            parent.focused = false
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.moveUp(_:)), let historyUp = parent.historyUp { historyUp(); return true }
            if commandSelector == #selector(NSResponder.moveDown(_:)), let historyDown = parent.historyDown { historyDown(); return true }
            if commandSelector == #selector(NSResponder.insertTab(_:)), let complete = parent.complete { complete(); return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = textView.string
                parent.submit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                parent.focused = false
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)), textView.string.isEmpty {
                parent.previous()
                return true
            }
            return false
        }
    }
}

/// 字段编辑器：⌘V 时如果剪贴板是图片，交给输入框的 onPasteImages，而不是粘贴成乱码或什么都不做。
final class ImagePasteTextView: NSTextView {
    override func paste(_ sender: Any?) {
        if let field = delegate as? TaskTextField, let handler = field.onPasteImages {
            let images = ImageTools.images(from: .general)
            if !images.isEmpty {
                handler(images)
                return
            }
        }
        super.paste(sender)
    }

    private var canPasteImages: Bool {
        (delegate as? TaskTextField)?.onPasteImages != nil && ImageTools.hasImage(.general)
    }

    // 默认情况下纯文本输入框遇到只有图片的剪贴板会禁用「粘贴」，⌘V 就不会触发。
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), canPasteImages { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), canPasteImages { return true }
        return super.validateMenuItem(item)
    }
}

final class ImagePasteCell: NSTextFieldCell {
    private static let editor: ImagePasteTextView = {
        let view = ImagePasteTextView()
        view.isFieldEditor = true
        return view
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { Self.editor }
}

final class TaskTextField: NSTextField {
    var onAttach: (() -> Void)?
    var onPasteImages: (([Data]) -> Void)?
    override class var cellClass: AnyClass? {
        get { ImagePasteCell.self }
        set {}
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach?() }
    }
}

@MainActor
final class LinkInsertion {
    static var presenting = false
    weak var field: NSTextField?
    var range = NSRange(location: 0, length: 0)
    var initialAddress = ""
    var initialLabel = ""

    init() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSTextField {
            self.field = field
            range = editor.selectedRange()
            let selected = (editor.string as NSString).substring(with: range)
            let rendered = TaskText.rendered(selected)
            if selected.hasPrefix("["), let url = rendered.runs.compactMap(\.link).first {
                initialAddress = url.absoluteString
                initialLabel = String(rendered.characters)
            } else if let url = TaskText.linkURL(selected) {
                initialAddress = url.absoluteString
            } else {
                initialLabel = selected
            }
        }
        if initialAddress.isEmpty, let clipboard = NSPasteboard.general.string(forType: .string), let url = TaskText.linkURL(clipboard) {
            initialAddress = url.absoluteString
        }
        Self.presenting = true
    }

    func finish(inserting link: String?) -> Bool {
        Self.presenting = false
        guard let field, let window = field.window else { return false }
        window.makeFirstResponder(field)
        if let link, let editor = field.currentEditor() as? NSTextView {
            let length = (editor.string as NSString).length
            let start = min(range.location, length)
            editor.insertText(link, replacementRange: NSRange(location: start, length: min(range.length, length - start)))
        }
        return true
    }
}
