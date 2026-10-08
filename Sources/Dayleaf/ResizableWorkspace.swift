import AppKit
import SwiftUI

enum ResizeAxis { case horizontal, vertical, both }

struct WorkspaceDimensions {
    let size: CGSize
    let left: CGFloat
    let tasksVisible: Bool
    /// 窗口过窄时清单与月历不再并排：清单展开则独占整个区域。
    static let narrowWidth: CGFloat = 860
    var narrow: Bool { size.width < Self.narrowWidth }

    init(size: CGSize, leftFraction: Double, tasksVisible: Bool = true) {
        self.size = size
        self.tasksVisible = tasksVisible
        let minimumLeft = min(300, size.width * 0.4)
        let minimumRight = min(460, size.width * 0.45)
        if tasksVisible, size.width < Self.narrowWidth {
            left = size.width
        } else {
            left = tasksVisible ? min(max(size.width * leftFraction, minimumLeft), size.width - minimumRight) : 0
        }
    }

    var tasksFrame: CGRect { CGRect(x: 0, y: 0, width: left, height: size.height) }
    var calendarFrame: CGRect { CGRect(x: left, y: 0, width: size.width - left, height: size.height) }

    func moving(_ delta: CGSize) -> WorkspaceDimensions {
        WorkspaceDimensions(size: size, leftFraction: (left + delta.width) / max(1, size.width), tasksVisible: tasksVisible)
    }
}

/// 主界面：左边待办清单（可收起），右边月历，中间的竖线可以拖动。当天的日志在 ⌘J 打开的 sheet 里。
struct ResizableWorkspace<Tasks: View, Calendar: View>: View {
    @AppStorage("workspaceLeftFraction") private var leftFraction = 0.36
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOrigin: WorkspaceDimensions?
    @State private var dragPosition: WorkspaceDimensions?
    @Binding var tasksVisible: Bool
    @ViewBuilder let tasks: () -> Tasks
    @ViewBuilder let calendar: () -> Calendar

    var body: some View {
        GeometryReader { geometry in
            let layout = dragPosition ?? WorkspaceDimensions(size: geometry.size, leftFraction: leftFraction, tasksVisible: tasksVisible)
            ZStack(alignment: .topLeading) {
                if tasksVisible {
                    tasks().frame(width: layout.tasksFrame.width, height: layout.tasksFrame.height).clipped()
                }
                if !(tasksVisible && layout.narrow) {
                    calendar().frame(width: layout.calendarFrame.width, height: layout.calendarFrame.height)
                        .clipped().offset(x: layout.left)
                }
                if tasksVisible, !layout.narrow {
                    handle(layout: layout).frame(width: 12, height: layout.size.height)
                        .offset(x: layout.left - 6)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: tasksVisible)
        }
    }

    private func handle(layout: WorkspaceDimensions) -> some View {
        ResizeHandle(axis: .horizontal, begin: {
            NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
            dragOrigin = layout
        }, change: { delta in
            dragPosition = (dragOrigin ?? layout).moving(delta)
        }, end: {
            if let position = dragPosition, tasksVisible { leftFraction = position.left / max(1, position.size.width) }
            dragPosition = nil
            dragOrigin = nil
        })
    }
}

struct ResizeHandle: NSViewRepresentable {
    let axis: ResizeAxis
    let begin: () -> Void
    let change: (CGSize) -> Void
    let end: () -> Void

    func makeNSView(context: Context) -> ResizeHandleView { ResizeHandleView() }
    func updateNSView(_ view: ResizeHandleView, context: Context) {
        view.axis = axis
        view.begin = begin
        view.change = change
        view.end = end
        view.toolTip = axis == .both ? "任意方向拖动，同时调整三个面板" : "拖动调整面板大小"
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(view.toolTip)
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

final class ResizeHandleView: NSView {
    var axis: ResizeAxis = .both
    var begin: (() -> Void)?
    var change: ((CGSize) -> Void)?
    var end: (() -> Void)?
    private var origin: NSPoint?
    private var hovered = false
    private var tracking: NSTrackingArea?

    override func resetCursorRects() {
        let cursor: NSCursor = axis == .both ? .crosshair : (axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { origin = event.locationInWindow; begin?() }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        change?(CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y))
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event); origin = nil; end?() }

    override func draw(_ dirtyRect: NSRect) {
        (hovered ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
        switch axis {
        case .horizontal:
            NSBezierPath(rect: NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)).fill()
        case .vertical:
            NSBezierPath(rect: NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)).fill()
        case .both:
            let inset: CGFloat = hovered ? 3 : 8
            NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 4, yRadius: 4).fill()
        }
    }
}
