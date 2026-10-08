import AppKit
import XCTest
@testable import Dayleaf

final class ResizableWorkspaceTests: XCTestCase {
    func testTerminalSpansBothUpperPanesAndCalendarAlwaysRemainsVisible() {
        let size = CGSize(width: 1200, height: 800)
        let expanded = WorkspaceDimensions(size: size, leftFraction: 0.4, topFraction: 0.6)
        XCTAssertEqual(expanded.tasksFrame.maxX, expanded.calendarFrame.minX)
        XCTAssertEqual(expanded.tasksFrame.maxY, expanded.terminalFrame.minY)
        XCTAssertEqual(expanded.calendarFrame.maxY, expanded.terminalFrame.minY)
        XCTAssertEqual(expanded.terminalFrame.width, size.width)
        XCTAssertEqual(expanded.terminalFrame.maxY, size.height)
        let hiddenTasks = WorkspaceDimensions(size: size, leftFraction: 0.4, topFraction: 0.6, tasksVisible: false)
        XCTAssertEqual(hiddenTasks.left, 0)
        XCTAssertEqual(hiddenTasks.calendarFrame.width, size.width)
        XCTAssertEqual(hiddenTasks.terminalFrame.width, size.width)
    }

    func testCollapsedTerminalLeavesOnlyBarAndResizingPreservesCollapsedPanes() {
        let size = CGSize(width: 1200, height: 800)
        let folded = WorkspaceDimensions(size: size, leftFraction: 0.4, topFraction: 0.6, tasksVisible: false, terminalVisible: false)
        XCTAssertEqual(folded.terminalFrame.height, 32)
        XCTAssertEqual(folded.calendarFrame, CGRect(x: 0, y: 0, width: 1200, height: 768))
        let moved = folded.moving(CGSize(width: 50, height: -80), axis: .both)
        XCTAssertEqual(moved.calendarFrame, folded.calendarFrame)
        let tasksOnly = WorkspaceDimensions(size: size, leftFraction: 0.4, topFraction: 0.6, terminalVisible: false)
        XCTAssertEqual(tasksOnly.tasksFrame.height, 768)
        XCTAssertEqual(tasksOnly.moving(CGSize(width: 50, height: -80), axis: .horizontal).left, tasksOnly.left + 50)
    }

    func testJunctionMovesBothDividersAndEdgesMoveOnlyTheirAxis() {
        let original = WorkspaceDimensions(size: CGSize(width: 1200, height: 800), leftFraction: 0.4, topFraction: 0.6)
        let delta = CGSize(width: 70, height: -60)
        let diagonal = original.moving(delta, axis: .both)
        XCTAssertEqual(diagonal.left, original.left + 70, accuracy: 0.001)
        XCTAssertEqual(diagonal.top, original.top - 60, accuracy: 0.001)
        XCTAssertEqual(original.moving(delta, axis: .horizontal).top, original.top, accuracy: 0.001)
        XCTAssertEqual(original.moving(delta, axis: .vertical).left, original.left, accuracy: 0.001)
    }

    func testDraggingToWindowEdgesPreservesUsablePanesAndRatios() {
        let original = WorkspaceDimensions(size: CGSize(width: 1200, height: 800), leftFraction: 0.4, topFraction: 0.6)
        let minimum = original.moving(CGSize(width: -2000, height: -2000), axis: .both)
        XCTAssertEqual(minimum.left, 300)
        XCTAssertEqual(minimum.top, 240)
        let maximum = original.moving(CGSize(width: 2000, height: 2000), axis: .both)
        XCTAssertEqual(maximum.left, 740)
        XCTAssertEqual(maximum.top, 620)
        let restored = WorkspaceDimensions(size: maximum.size,
                                           leftFraction: maximum.left / maximum.size.width,
                                           topFraction: maximum.top / maximum.size.height)
        XCTAssertEqual(restored.left, maximum.left, accuracy: 0.001)
        XCTAssertEqual(restored.top, maximum.top, accuracy: 0.001)
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

    func testFutureDatesGiveTheWholeHeightToTasksAndCalendar() {
        let size = CGSize(width: 1200, height: 800)
        let layout = WorkspaceDimensions(size: size, leftFraction: 0.4, topFraction: 0.6, terminalAvailable: false)
        XCTAssertEqual(layout.tasksFrame.height, size.height)
        XCTAssertEqual(layout.calendarFrame.height, size.height)
        XCTAssertEqual(layout.terminalFrame.height, 0)
    }

    func testNarrowWindowShowsTasksAloneInsteadOfSqueezingTheCalendar() {
        let narrow = WorkspaceDimensions(size: CGSize(width: 700, height: 700), leftFraction: 0.4, topFraction: 0.6)
        XCTAssertTrue(narrow.narrow)
        XCTAssertEqual(narrow.tasksFrame.width, 700)
        XCTAssertEqual(narrow.calendarFrame.width, 0)
    }
}
