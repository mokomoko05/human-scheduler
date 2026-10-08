import AppKit
import SwiftUI
import DayleafCore

/// 点击月份标题弹出：快速跳到任意年月。
struct MonthJumper: View {
    let current: Date
    let jump: (Date) -> Void
    @State private var year: Int

    init(current: Date, jump: @escaping (Date) -> Void) {
        self.current = current
        self.jump = jump
        _year = State(initialValue: JournalDates.calendar.component(.year, from: current))
    }

    var body: some View {
        let calendar = JournalDates.calendar
        let currentYear = calendar.component(.year, from: current)
        let currentMonth = calendar.component(.month, from: current)
        VStack(spacing: 10) {
            HStack {
                Button { year -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(HitAreaButtonStyle()).accessibilityLabel("上一年")
                Spacer()
                Text(String(year)).font(.system(size: UIScale.pt(14), weight: .semibold, design: .rounded))
                Spacer()
                Button { year += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(HitAreaButtonStyle()).accessibilityLabel("下一年")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(1...12, id: \.self) { month in
                    let selected = year == currentYear && month == currentMonth
                    Button { if let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) { jump(date) } } label: {
                        Text("\(month)月").font(.system(size: UIScale.pt(13), weight: selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(selected ? Palette.accent : Palette.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(selected ? Color.white : Palette.ink)
                    }.buttonStyle(.plain)
                }
            }
            Button("回到本月") { jump(Date()) }.buttonStyle(HitAreaButtonStyle()).font(.system(size: UIScale.pt(12))).foregroundStyle(Palette.accent)
        }
        .padding(14).frame(width: 240)
    }
}

/// 在日历区域内用触控板横向轻扫切换月份；纵向滚动不受影响。
struct MonthSwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView {
        let view = SwipeView()
        view.install()
        return view
    }

    func updateNSView(_ view: SwipeView, context: Context) { view.onSwipe = onSwipe }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.remove() }

    final class SwipeView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, window.attachedSheet == nil, event.hasPreciseScrollingDeltas else { return }
            if event.phase == .began || event.phase == .mayBegin { accumulated = 0; fired = false }
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 {
                accumulated += event.scrollingDeltaX
                if !fired, abs(accumulated) > 70 {
                    fired = true
                    onSwipe?(accumulated < 0 ? 1 : -1)
                }
            }
            if event.phase == .ended || event.phase == .cancelled { accumulated = 0; fired = false }
        }
    }
}
