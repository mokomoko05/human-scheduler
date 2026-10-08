import AppKit
import XCTest
@testable import Dayleaf

final class ResizableWorkspaceTests: XCTestCase {
    func testTasksAndCalendarShareTheFullHeightAndCalendarAlwaysRemainsVisible() {
        let size = CGSize(width: 1200, height: 800)
        let expanded = WorkspaceDimensions(size: size, leftFraction: 0.4)
        XCTAssertEqual(expanded.tasksFrame.maxX, expanded.calendarFrame.minX)
        XCTAssertEqual(expanded.tasksFrame.height, size.height, "不再有底部的日志区，清单和月历占满整个高度")
        XCTAssertEqual(expanded.calendarFrame.height, size.height)
        let hiddenTasks = WorkspaceDimensions(size: size, leftFraction: 0.4, tasksVisible: false)
        XCTAssertEqual(hiddenTasks.left, 0)
        XCTAssertEqual(hiddenTasks.calendarFrame.width, size.width)
    }

    func testDraggingTheDividerKeepsBothPanesUsableAndRatioRoundTrips() {
        let original = WorkspaceDimensions(size: CGSize(width: 1200, height: 800), leftFraction: 0.4)
        XCTAssertEqual(original.moving(CGSize(width: 70, height: 0)).left, original.left + 70, accuracy: 0.001)
        XCTAssertEqual(original.moving(CGSize(width: -2000, height: 0)).left, 300, "清单最窄 300")
        let maximum = original.moving(CGSize(width: 2000, height: 0))
        XCTAssertEqual(maximum.left, 740, "月历至少留 460")
        let restored = WorkspaceDimensions(size: maximum.size, leftFraction: maximum.left / maximum.size.width)
        XCTAssertEqual(restored.left, maximum.left, accuracy: 0.001)
    }

    @MainActor
    func testNativeResizeDragUsesWindowCoordinatesAcrossMovingHandle() async throws {
        let view = ResizeHandleView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var began = false
        var ended = false
        var translation: CGSize?
        view.begin = { began = true }
        view.change = { translation = $0 }
        view.end = { ended = true }
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 400, y: 300),
                                                   modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 480, y: 250),
                                                   modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        view.frame.origin = NSPoint(x: 80, y: 50)
        view.mouseDragged(with: drag)
        view.mouseUp(with: drag)
        XCTAssertTrue(began)
        XCTAssertTrue(ended)
        XCTAssertEqual(translation, CGSize(width: 80, height: 50))
    }

    func testNarrowWindowShowsTasksAloneInsteadOfSqueezingTheCalendar() {
        let narrow = WorkspaceDimensions(size: CGSize(width: 700, height: 700), leftFraction: 0.4)
        XCTAssertTrue(narrow.narrow)
        XCTAssertEqual(narrow.tasksFrame.width, 700)
        XCTAssertEqual(narrow.calendarFrame.width, 0)
    }
}
