import AppKit
import SwiftUI
import XCTest
@testable import Dayleaf

@MainActor
final class GrowingInputTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 13)
    private let long = String(repeating: "这是一大段粘贴进来的内容，会折成很多行。Pasted text that wraps. ", count: 12)

    private func input(_ text: String, minHeight: CGFloat? = 24, maxLines: Int = 10, allowsNewlines: Bool = true) -> TaskInput {
        TaskInput(text: .constant(text), focused: .constant(false), submit: {}, minHeight: minHeight, maxLines: maxLines, allowsNewlines: allowsNewlines)
    }

    func testHeightGrowsWithWrappedAndExplicitLinesUpToTheCap() {
        let one = TaskInput.height(for: "一行", font: font, width: 400, minHeight: 24, maxLines: 10)
        XCTAssertEqual(one, 24, accuracy: 0.5, "单行时就是原来的高度")
        XCTAssertEqual(TaskInput.height(for: "", font: font, width: 400, minHeight: 24, maxLines: 10), 24, accuracy: 0.5)
        let three = TaskInput.height(for: "甲\n乙\n丙", font: font, width: 400, minHeight: 24, maxLines: 10)
        XCTAssertGreaterThan(three, one + 20, "显式换行也增高")
        XCTAssertGreaterThan(TaskInput.height(for: "甲\n", font: font, width: 400, minHeight: 24, maxLines: 10), one, "末尾的空行也算")
        let wide = TaskInput.height(for: long, font: font, width: 800, minHeight: 24, maxLines: 40)
        let narrow = TaskInput.height(for: long, font: font, width: 300, minHeight: 24, maxLines: 40)
        XCTAssertGreaterThan(narrow, wide, "越窄折行越多")
        XCTAssertGreaterThan(wide, one)
        let capped = TaskInput.height(for: long, font: font, width: 200, minHeight: 24, maxLines: 5)
        XCTAssertEqual(capped, 5 * ceil(font.ascender - font.descender + font.leading) + (24 - ceil(font.ascender - font.descender + font.leading)), accuracy: 0.5, "到上限为止")
    }

    /// 估算的高度不能比真实排版矮，否则最后一行会被裁掉。
    func testEstimateIsNeverShorterThanRealTextFieldLayout() {
        for width in [180.0, 260, 340, 480, 700] {
            let cell = NSTextFieldCell(textCell: long)
            cell.font = font
            cell.wraps = true
            cell.isScrollable = false
            cell.lineBreakMode = .byWordWrapping
            let real = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height
            let estimate = TaskInput.height(for: long, font: font, width: width, minHeight: 24, maxLines: 100)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            XCTAssertGreaterThanOrEqual(estimate - (24 - lineHeight), real - 4, "宽 \(width)：估算 \(estimate) 不应明显低于真实 \(real)")
        }
    }

    func testSwiftUIReportsTheGrownHeightAndLegacySingleLineIsUntouched() {
        func fitted(_ view: TaskInput) -> NSSize {
            let host = NSHostingView(rootView: view.frame(width: 320))
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            Self.keepAlive += [window, host]
            return host.fittingSize
        }
        let short = fitted(input("短"))
        let tall = fitted(input(long))
        XCTAssertEqual(short.height, 24, accuracy: 1)
        XCTAssertGreaterThan(tall.height, short.height * 3, "粘贴大段内容后输入框自动增高")
        XCTAssertLessThanOrEqual(tall.height, 10 * 17 + 8, "不超过 10 行")
    }

    func testPastedNewlinesBecomeSpacesOnlyForSingleLineContent() {
        func run(allowsNewlines: Bool) -> String {
            var text = ""
            let todo = TaskInput(text: Binding(get: { text }, set: { text = $0 }), focused: .constant(false), submit: {},
                                 minHeight: 22, maxLines: 6, allowsNewlines: allowsNewlines)
            let field = TaskTextField()
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = field
            Self.keepAlive += [window]
            window.makeFirstResponder(field)
            field.stringValue = "甲\n乙\n丙"
            if let editor = field.currentEditor() { editor.string = "甲\n乙\n丙" }
            todo.makeCoordinator().controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            return text
        }
        XCTAssertEqual(run(allowsNewlines: false), "甲 乙 丙", "待办标题里粘贴的换行变成空格")
        XCTAssertEqual(run(allowsNewlines: true), "甲\n乙\n丙", "日志、笔记保留换行")
    }

    private static var keepAlive: [AnyObject] = []
}

/// 快速浮窗的位置按顶边记：高度变了，顶边也不动。
@MainActor
final class QuickPanelPositionTests: XCTestCase {
    func testTopEdgeSurvivesAHeightChange() {
        let closed = NSRect(x: 300, y: 500, width: 520, height: 230)
        let saved = QuickCaptureController.topLeft(of: closed)
        // 下次打开时窗口先是 160 高，布局后长到 190：两种高度下顶边都回到同一处。
        for height in [160.0, 190, 230, 320] {
            let origin = QuickCaptureController.origin(topLeft: saved, height: height)
            XCTAssertEqual(origin.y + height, closed.maxY, accuracy: 0.001)
            XCTAssertEqual(origin.x, closed.minX)
        }
    }
}
