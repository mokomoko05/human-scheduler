import AppKit
import SwiftUI

enum ResizeAxis { case horizontal, vertical, both }

struct WorkspaceDimensions {
    let size: CGSize
    let left: CGFloat
    let top: CGFloat
    let tasksVisible: Bool
    let terminalVisible: Bool
    let terminalAvailable: Bool
    /// 窗口过窄时清单与月历不再并排：清单展开则独占上方区域。
    static let narrowWidth: CGFloat = 860
    var narrow: Bool { size.width < Self.narrowWidth }

    init(size: CGSize, leftFraction: Double, topFraction: Double, tasksVisible: Bool = true, terminalVisible: Bool = true, terminalAvailable: Bool = true) {
        self.size = size
        self.tasksVisible = tasksVisible
        self.terminalVisible = terminalVisible
        self.terminalAvailable = terminalAvailable
        let minimumLeft = min(300, size.width * 0.4)
        let minimumRight = min(460, size.width * 0.45)
        let minimumTop = min(240, size.height * 0.4)
        let minimumBottom = min(180, size.height * 0.3)
        if tasksVisible, size.width < Self.narrowWidth {
            left = size.width
        } else {
            left = tasksVisible ? min(max(size.width * leftFraction, minimumLeft), size.width - minimumRight) : 0
        }
        if !terminalAvailable {
            top = size.height
        } else {
            top = terminalVisible ? min(max(size.height * topFraction, minimumTop), size.height - minimumBottom) : max(0, size.height - 32)
        }
    }

    var tasksFrame: CGRect { CGRect(x: 0, y: 0, width: left, height: top) }
    var calendarFrame: CGRect { CGRect(x: left, y: 0, width: size.width - left, height: top) }
    var terminalFrame: CGRect { CGRect(x: 0, y: top, width: size.width, height: size.height - top) }

    func moving(_ delta: CGSize, axis: ResizeAxis) -> WorkspaceDimensions {
        WorkspaceDimensions(size: size,
                            leftFraction: (left + (axis == .vertical ? 0 : delta.width)) / max(1, size.width),
                            topFraction: (top + (axis == .horizontal ? 0 : delta.height)) / max(1, size.height),
                            tasksVisible: tasksVisible, terminalVisible: terminalVisible, terminalAvailable: terminalAvailable)
    }
}

struct ResizableWorkspace<Tasks: View, Summary: View, Calendar: View>: View {
    @AppStorage("workspaceLeftFraction") private var leftFraction = 0.36
    @AppStorage("workspaceTopFraction") private var topFraction = 0.66
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOrigin: WorkspaceDimensions?
    @State private var dragPosition: WorkspaceDimensions?
    @Binding var tasksVisible: Bool
    @Binding var terminalVisible: Bool
    /// 未来的日期不显示终端，整个区域留给清单和月历。
    var terminalAvailable = true
    @ViewBuilder let tasks: () -> Tasks
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let calendar: () -> Calendar

    var body: some View {
        GeometryReader { geometry in
            let layout = dragPosition ?? WorkspaceDimensions(size: geometry.size, leftFraction: leftFraction, topFraction: topFraction,
                                                             tasksVisible: tasksVisible, terminalVisible: terminalVisible, terminalAvailable: terminalAvailable)
            ZStack(alignment: .topLeading) {
                if tasksVisible {
                    tasks().frame(width: layout.tasksFrame.width, height: layout.tasksFrame.height).clipped()
                }
                if !terminalAvailable {
                    EmptyView()
                } else if terminalVisible {
                    summary().frame(width: layout.terminalFrame.width, height: layout.terminalFrame.height)
                        .clipped().offset(y: layout.top)
                } else {
                    Button { terminalVisible = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "terminal")
                            Text("终端  ⌘J").font(.system(size: UIScale.pt(11), design: .monospaced))
                            Spacer()
                            Image(systemName: "chevron.up")
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(TerminalPalette.text)
                    .background(TerminalPalette.panel)
                    .frame(width: layout.terminalFrame.width, height: layout.terminalFrame.height)
                    .offset(y: layout.top)
                    .help("展开终端")
                }
                if !(tasksVisible && layout.narrow) {
                    calendar().frame(width: layout.calendarFrame.width, height: layout.calendarFrame.height)
                        .clipped().offset(x: layout.left)
                }
                if tasksVisible, !layout.narrow {
                    handle(.horizontal, layout: layout).frame(width: 12, height: layout.top)
                        .offset(x: layout.left - 6)
                }
                if terminalVisible && terminalAvailable {
                    handle(.vertical, layout: layout).frame(width: layout.size.width, height: 12)
                        .offset(y: layout.top - 6)
                }
                if tasksVisible && terminalVisible && terminalAvailable && !layout.narrow {
                    handle(.both, layout: layout).frame(width: 24, height: 24)
                        .offset(x: layout.left - 12, y: layout.top - 12)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: tasksVisible)
        }
    }

    private func handle(_ axis: ResizeAxis, layout: WorkspaceDimensions) -> some View {
        ResizeHandle(axis: axis, begin: {
            NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
            dragOrigin = layout
        }, change: { delta in
            dragPosition = (dragOrigin ?? layout).moving(delta, axis: axis)
        }, end: {
            if let position = dragPosition {
                if tasksVisible { leftFraction = position.left / max(1, position.size.width) }
                if terminalVisible { topFraction = position.top / max(1, position.size.height) }
            }
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
