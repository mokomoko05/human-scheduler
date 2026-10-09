import AppKit
import SwiftUI
import XCTest
@testable import Dayleaf

@MainActor
final class RadialMenuTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        RadialMenuController.shared.dismiss()
    }

    private func items(_ count: Int, fired: @escaping (Int) -> Void = { _ in }) -> [RadialItem] {
        (0..<count).map { index in RadialItem(id: "i\(index)", symbol: "circle", title: "项\(index)", action: { fired(index) }) }
    }

    func testFanSpreadsEvenlyAcrossTheLeftSideAndStaysInsideThePanel() {
        for count in 1...6 {
            let angles = RadialLayout.angles(count: count)
            XCTAssertEqual(angles.count, count)
            XCTAssertTrue(angles.allSatisfy { $0 >= RadialLayout.fanStart && $0 <= RadialLayout.fanEnd })
            for index in 0..<count {
                let offset = RadialLayout.offset(index: index, count: count)
                let center = CGPoint(x: RadialLayout.hub.x + offset.width, y: RadialLayout.hub.y + offset.height)
                let half = RadialLayout.itemSize / 2
                XCTAssertGreaterThanOrEqual(center.x - half, 0, "项 \(index)/\(count) 不超出浮层左边")
                XCTAssertGreaterThanOrEqual(center.y - half, 0)
                XCTAssertLessThanOrEqual(center.y + half, RadialLayout.panelSize.height)
                XCTAssertLessThanOrEqual(offset.width, 1, "只向左展开，不盖住右边的拖动把手")
            }
        }
        XCTAssertEqual(RadialLayout.angles(count: 1), [180], "只有一项就正对左边")
        let five = RadialLayout.angles(count: 5)
        XCTAssertEqual(five.first, RadialLayout.fanStart)
        XCTAssertEqual(five.last, RadialLayout.fanEnd)
        XCTAssertEqual(five[1] - five[0], five[2] - five[1], accuracy: 0.001)
    }

    func testHitTestingFollowsTheItemsAndTheFanShape() {
        let count = 5
        for index in 0..<count {
            let offset = RadialLayout.offset(index: index, count: count)
            // 视图坐标 y 向下 → 屏幕坐标 y 向上。
            let point = CGPoint(x: offset.width, y: -offset.height)
            XCTAssertTrue(RadialLayout.contains(point))
            XCTAssertEqual(RadialLayout.item(at: point, count: count), index)
        }
        XCTAssertTrue(RadialLayout.contains(.zero), "圆心（三点按钮本身）在菜单上")
        XCTAssertNil(RadialLayout.item(at: .zero, count: count))
        XCTAssertFalse(RadialLayout.contains(CGPoint(x: 60, y: 0)), "右边（拖动把手一侧）不算")
        XCTAssertFalse(RadialLayout.contains(CGPoint(x: -140, y: 0)), "离得远了就算离开")
        XCTAssertFalse(RadialLayout.contains(CGPoint(x: 50, y: 50)), "右上方向没有扇形")
    }

    func testPresentTracksHoverChooseFiresAndDismisses() {
        var fired: [Int] = []
        let menu = RadialMenuController.shared
        menu.present(items: items(4) { fired.append($0) }, hubAt: CGPoint(x: 600, y: 500))
        XCTAssertTrue(menu.isOpen)
        let offset = RadialLayout.offset(index: 2, count: 4)
        menu.update(mouse: CGPoint(x: 600 + offset.width, y: 500 - offset.height))
        XCTAssertEqual(menu.hoveredIndex, 2, "鼠标指着哪项，哪项就高亮")
        menu.update(mouse: CGPoint(x: 600, y: 500))
        XCTAssertNil(menu.hoveredIndex)
        XCTAssertTrue(menu.isOpen)
        menu.dismiss()
        XCTAssertFalse(menu.isOpen)
        XCTAssertTrue(fired.isEmpty)
    }

    func testMenuClosesOnlyAfterTheMouseHasBeenAwayForTheGracePeriod() {
        let menu = RadialMenuController.shared
        menu.present(items: items(3), hubAt: CGPoint(x: 600, y: 500))
        let start = Date()
        let away = CGPoint(x: 900, y: 500)
        menu.update(mouse: away, now: start)
        XCTAssertTrue(menu.isOpen, "刚离开不立刻收起")
        menu.update(mouse: CGPoint(x: 600, y: 500), now: start.addingTimeInterval(0.1))
        menu.update(mouse: away, now: start.addingTimeInterval(0.15))
        menu.update(mouse: away, now: start.addingTimeInterval(0.25))
        XCTAssertTrue(menu.isOpen, "中途回来过，计时重新开始")
        menu.update(mouse: away, now: start.addingTimeInterval(0.15 + RadialMenuController.grace + 0.01))
        XCTAssertFalse(menu.isOpen, "离开超过宽限时间才收起")
    }

    func testPresentingAgainReplacesTheOldMenuAndEmptyItemsOpenNothing() {
        let menu = RadialMenuController.shared
        menu.present(items: items(2), hubAt: CGPoint(x: 100, y: 100))
        menu.present(items: items(5), hubAt: CGPoint(x: 300, y: 300))
        XCTAssertEqual(menu.openItems.count, 5)
        let anchor = NSView()
        menu.present(items: [], anchor: anchor)
        XCTAssertEqual(menu.openItems.count, 5, "没有操作、或锚点不在窗口里，什么都不改")
    }

    func testViewRendersEveryItemInsideTheFixedPanelSize() throws {
        let model = RadialMenuModel(items: items(5))
        model.hovered = 1
        let host = NSHostingView(rootView: RadialMenuView(model: model))
        let window = QuietWindow(contentRect: NSRect(origin: .zero, size: RadialLayout.panelSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, RadialLayout.panelSize.width, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, RadialLayout.panelSize.height, accuracy: 1)
    }
}
