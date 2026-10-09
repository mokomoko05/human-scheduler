import AppKit
import Combine
import SwiftUI
import DayleafCore

private struct FocusSessionKey: EnvironmentKey {
    static let defaultValue: FocusSession? = nil
}

extension EnvironmentValues {
    var focusSession: FocusSession? {
        get { self[FocusSessionKey.self] }
        set { self[FocusSessionKey.self] = newValue }
    }
}

/// 一次专注计时：打开任务里的链接并开始计时，日志记录开始时间；
/// 之后每秒检查前台是否还是目标页面，离开就停止计时并在日志里记下用时和原因。
@MainActor
final class FocusSession: ObservableObject {
    struct Active: Equatable {
        let taskID: UUID
        let number: Int?
        let title: String
        let url: URL
        let started: Date
        /// 「开始专注」那条日志；专注太短时要把它撤掉。
        var startLogID: UUID?
    }

    @Published private(set) var active: Active?
    @Published private(set) var elapsed: TimeInterval = 0
    var store: JournalStore?
    var onActiveChange: ((Bool) -> Void)?
    /// 专注不足这么长（秒）就不在日志里留记录；默认读设置，测试里可替换。
    var minLoggedSeconds: () -> TimeInterval = { Prefs.focusMinLogSeconds }
    /// 没有授权控制 Safari、只能检测是否离开 Safari 时调用一次（每次专注一次），由界面用提示条告知。
    var onDegraded: (() -> Void)?
    /// 打开链接的动作；测试里替换掉，避免真的启动 Safari。
    var openLink: (URL) -> Void = { SafariLinks.launch($0) }
    /// 页面已在 Safari 里开着时，直接切换到那个标签页（保留滚动位置，不重新加载）。成功返回 true；测试里替换掉。
    var activateExistingTab: (URL) async -> Bool = { await FocusProbe.activateExistingTab(for: $0) }

    private var timer: Timer?
    private var awayStreak = 0
    private var baseline: Baseline?
    private var checking = false
    private var learnedBundle: String?
    private var automationDenied = false

    /// 刚打开页面时留出加载和重定向的时间，期间不判定离开。
    static let grace: TimeInterval = 6
    /// 连续几次（每次 1 秒）不在目标页面才算离开，避免通知、Spotlight 一闪而过造成误判。
    static let awayThreshold = 2

    struct Baseline: Equatable, Sendable { var host: String; var path: String }

    // MARK: - 链接

    /// 任务标题里的第一个网页或本地文件链接。
    static func link(in title: String) -> URL? {
        TaskText.rendered(title).runs.compactMap(\.link).first { $0.isFileURL || ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    nonisolated static func baseline(for url: URL) -> Baseline {
        if url.isFileURL { return Baseline(host: "", path: url.standardizedFileURL.path) }
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return Baseline(host: host, path: path)
    }

    nonisolated static func matches(_ current: URL, _ baseline: Baseline) -> Bool {
        self.baseline(for: current) == baseline
    }

    // MARK: - 开始与结束

    func start(task: ScheduledTask, url: URL, now: Date = Date()) {
        guard let store, !store.isReadOnly else { return }
        if active != nil { stop(reason: "切换到了另一个任务", now: now) }
        let number = task.task.number
        active = Active(taskID: task.id, number: number, title: String(TaskText.rendered(task.task.title).characters), url: url, started: now)
        elapsed = 0
        awayStreak = 0
        learnedBundle = nil
        automationDenied = false
        baseline = Self.baseline(for: url)
        active?.startLogID = store.addFocusLog("▶ 开始专注", taskID: task.id, now: now)
        store.setFocusTask(task.id)
        // 已经开着就切过去，不要再打开一次，否则会回到页面开头。
        Task { @MainActor in
            if await activateExistingTab(url) { return }
            openLink(url)
        }
        onActiveChange?(true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop(reason: String, now: Date = Date()) {
        guard let session = active else { return }
        timer?.invalidate()
        timer = nil
        let seconds = max(0, now.timeIntervalSince(session.started))
        if seconds < minLoggedSeconds() {
            // 太短：不留日志（撤掉开始那条、不写结束那条），时间照常累加。
            store?.discardShortFocus(startLogID: session.startLogID, taskID: session.taskID, seconds: seconds, now: now)
        } else {
            let total = (store?.locate(session.taskID)?.task.focusSeconds ?? 0) + seconds
            store?.addFocusLog("■ 结束专注 · 用时 \(Self.duration(seconds)) · 累计 \(Self.duration(total)) · \(reason)",
                               taskID: session.taskID, now: now, seconds: seconds)
        }
        store?.setFocusTask(nil)
        active = nil
        elapsed = 0
        baseline = nil
        onActiveChange?(false)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        if h > 0 { return "\(h) 小时 \(m) 分 \(s) 秒" }
        if m > 0 { return "\(m) 分 \(s) 秒" }
        return "\(s) 秒"
    }

    /// 任务行上的累计时长：「1 小时 20 分」「25 分钟」「40 秒」。
    static func brief(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m) = (total / 3600, (total % 3600) / 60)
        if h > 0 { return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时" }
        if m > 0 { return "\(m) 分钟" }
        return "\(total) 秒"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - 检测

    private func tick() {
        guard let session = active else { return }
        elapsed = Date().timeIntervalSince(session.started)
        guard !checking else { return }
        checking = true
        let inGrace = elapsed < Self.grace
        let target = session.url
        let currentBaseline = baseline
        let learned = learnedBundle
        Task { @MainActor in
            let result = await FocusProbe.check(target: target, baseline: currentBaseline, learnedBundle: learned)
            checking = false
            guard let session = active, session.taskID == self.active?.taskID else { return }
            apply(result, inGrace: inGrace)
        }
    }

    func apply(_ result: FocusProbe.Result, inGrace: Bool) {
        if result.automationDenied, !automationDenied { onDegraded?() }
        automationDenied = result.automationDenied
        // Scheduler 自己在前台（在这里记阅读笔记）不算离开：计时照常累计，离开计数清零。
        if result.ownApp {
            awayStreak = 0
            return
        }
        if inGrace {
            // 宽限期内：记住实际打开的页面（可能经过重定向）和应用，之后以它们为准。
            if let page = result.pageURL { baseline = Self.baseline(for: page) }
            if let bundle = result.frontBundle, bundle != Bundle.main.bundleIdentifier { learnedBundle = bundle }
            awayStreak = 0
            return
        }
        if result.onTarget {
            awayStreak = 0
            return
        }
        awayStreak += 1
        if awayStreak >= Self.awayThreshold { stop(reason: result.awayReason) }
    }
}

/// 读取前台应用和 Safari 当前标签页的地址。
@MainActor
enum FocusProbe {
    struct Result {
        var onTarget: Bool
        var awayReason: String
        var frontBundle: String?
        var pageURL: URL?
        var automationDenied: Bool
        /// Scheduler 自己在前台。
        var ownApp = false
    }

    static func check(target: URL, baseline: FocusSession.Baseline?, learnedBundle: String?) async -> Result {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let front, front == Bundle.main.bundleIdentifier {
            return Result(onTarget: true, awayReason: "", frontBundle: front, pageURL: nil, automationDenied: false, ownApp: true)
        }
        let usesSafari = SafariLinks.usesSafari(target)
        let expectedBundle = usesSafari ? "com.apple.Safari" : learnedBundle
        // 先看前台应用是不是目标应用。
        if let expectedBundle, front != expectedBundle {
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "其他应用"
            return Result(onTarget: false, awayReason: "切换到了\(name)", frontBundle: front, pageURL: nil, automationDenied: false)
        }
        guard usesSafari else {
            return Result(onTarget: true, awayReason: "", frontBundle: front, pageURL: nil, automationDenied: false)
        }
        // 再看 Safari 当前标签页是不是目标页面。
        switch await safariFrontURL() {
        case .denied:
            return Result(onTarget: true, awayReason: "", frontBundle: front, pageURL: nil, automationDenied: true)
        case .none:
            return Result(onTarget: false, awayReason: "Safari 没有打开的页面", frontBundle: front, pageURL: nil, automationDenied: false)
        case .url(let url):
            let match = baseline.map { FocusSession.matches(url, $0) } ?? true
            return Result(onTarget: match, awayReason: "离开了目标页面", frontBundle: front, pageURL: url, automationDenied: false)
        }
    }

    /// 在所有 Safari 窗口的所有标签页里找到目标页面，切换过去并置前。找不到、Safari 没运行或没有授权时返回 false，由调用方照常打开链接。
    static func activateExistingTab(for target: URL) async -> Bool {
        guard SafariLinks.usesSafari(target),
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else { return false }
        let list = """
        set output to ""
        tell application "Safari"
            repeat with w in windows
                try
                    set wid to id of w
                    repeat with i from 1 to (count of tabs of w)
                        try
                            set u to URL of tab i of w
                            if u is not missing value then set output to output & wid & (ASCII character 9) & i & (ASCII character 9) & u & linefeed
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return output
        """
        let (status, output, _) = await run("/usr/bin/osascript", ["-e", list], timeout: 3)
        guard status == 0, let found = bestTab(in: output, for: target) else { return false }
        let select = """
        tell application "Safari"
            set w to window id \(found.window)
            set current tab of w to tab \(found.tab) of w
            set index of w to 1
            activate
        end tell
        """
        return await run("/usr/bin/osascript", ["-e", select], timeout: 3).0 == 0
    }

    /// 解析「窗口id⇥标签序号⇥网址」逐行输出，返回第一个与目标页面匹配的标签（忽略参数、锚点、www 和末尾斜杠）。
    nonisolated static func bestTab(in output: String, for target: URL) -> (window: Int, tab: Int)? {
        let baseline = FocusSession.baseline(for: target)
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let window = Int(fields[0]), let tab = Int(fields[1]),
                  let url = URL(string: String(fields[2]).trimmingCharacters(in: .whitespaces)),
                  FocusSession.matches(url, baseline) else { continue }
            return (window, tab)
        }
        return nil
    }

    enum SafariURL { case url(URL), none, denied }

    static func safariFrontURL() async -> SafariURL {
        let script = """
        tell application "Safari"
            if (count of windows) is 0 then return ""
            return URL of current tab of front window
        end tell
        """
        let (status, output, error) = await run("/usr/bin/osascript", ["-e", script], timeout: 2)
        if status != 0 {
            // -1743：用户没有授权 Scheduler 控制 Safari。
            return error.contains("-1743") || error.contains("not allowed") || error.contains("不允许") ? .denied : .none
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text) else { return .none }
        return .url(url)
    }

    private nonisolated static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> (Int32, String, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch { continuation.resume(returning: (-1, "", error.localizedDescription)); return }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let output = out.fileHandleForReading.readDataToEndOfFile()
                let errors = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self)))
            }
        }
    }
}

// MARK: - 专注计时的显示：多种样式，可以隐藏

/// 计时窗口的样式。别人看到屏幕时，越低调越好：从完整的卡片到只有一个小点，或者只放在菜单栏里。
enum FocusPanelStyle: String, CaseIterable, Identifiable {
    case card, pill, digits, dot, menuBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .card: return "卡片"
        case .pill: return "胶囊"
        case .digits: return "数字"
        case .dot: return "小点"
        case .menuBar: return "菜单栏"
        }
    }

    var detail: String {
        switch self {
        case .card: return "时间、任务名和结束键，最完整"
        case .pill: return "只有时间和结束键，不显示任务名"
        case .digits: return "只有一行淡淡的数字，没有底板"
        case .dot: return "平时只是一个小圆点，鼠标移上去才显示时间"
        case .menuBar: return "不开浮窗，时间显示在菜单栏里"
        }
    }

    /// 浮动窗口的大小；菜单栏样式没有浮动窗口。
    var panelSize: NSSize? {
        switch self {
        case .card: return NSSize(width: 254, height: 56)
        case .pill: return NSSize(width: 152, height: 40)
        case .digits: return NSSize(width: 108, height: 30)
        case .dot: return NSSize(width: 132, height: 32)
        case .menuBar: return nil
        }
    }

    static var current: FocusPanelStyle {
        UserDefaults.standard.string(forKey: Prefs.focusPanelStyle).flatMap(FocusPanelStyle.init(rawValue:)) ?? .card
    }

    static var hidden: Bool { UserDefaults.standard.bool(forKey: Prefs.focusPanelHidden) }

    /// 隐藏 / 显示计时（专注照常进行，日志和累计时间不受影响）。
    static func toggleHidden() { UserDefaults.standard.set(!hidden, forKey: Prefs.focusPanelHidden) }

    /// 浮动窗口要不要显示：专注中、没被隐藏、而且样式有浮窗。
    static func floatingVisible(active: Bool, hidden: Bool, style: FocusPanelStyle) -> Bool {
        active && !hidden && style.panelSize != nil
    }

    /// 菜单栏的计时要不要显示。
    static func menuBarVisible(active: Bool, hidden: Bool, style: FocusPanelStyle) -> Bool {
        active && !hidden && style == .menuBar
    }
}

private final class FocusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

@MainActor
final class FocusPanelController: NSObject, NSWindowDelegate {
    private var panel: FocusPanel?
    private var statusItem: NSStatusItem?
    private let session: FocusSession
    private var observers: [NSObjectProtocol] = []
    private var elapsedSink: AnyCancellable?
    private let defaults: UserDefaults

    init(session: FocusSession, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        super.init()
        session.onActiveChange = { [weak self] _ in self?.refresh() }
        // 设置里改了样式、按了隐藏快捷键，立刻生效。
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        elapsedSink = session.$elapsed.sink { [weak self] _ in self?.updateStatusTitle() }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var style: FocusPanelStyle {
        defaults.string(forKey: Prefs.focusPanelStyle).flatMap(FocusPanelStyle.init(rawValue:)) ?? .card
    }

    /// 按「是否专注中 / 是否隐藏 / 样式」让窗口和菜单栏项目处于正确的状态。
    func refresh() {
        let active = session.active != nil
        let hidden = defaults.bool(forKey: Prefs.focusPanelHidden)
        let style = style
        if FocusPanelStyle.floatingVisible(active: active, hidden: hidden, style: style), let size = style.panelSize {
            showPanel(size: size)
        } else {
            panel?.orderOut(nil)
        }
        if FocusPanelStyle.menuBarVisible(active: active, hidden: hidden, style: style) { showStatusItem() } else { removeStatusItem() }
    }

    /// 当前显示着什么（测试用）。
    var isPanelVisible: Bool { panel?.isVisible == true }
    /// 菜单栏里该不该有计时（测试环境不真的创建菜单栏项目，免得在用户的菜单栏上闪一下）。
    private(set) var showsMenuBarTimer = false

    private func showPanel(size: NSSize) {
        let created = panel == nil
        if panel == nil {
            let host = NSHostingView(rootView: FocusPanelView(session: session))
            host.setFrameSize(size)
            // 不激活的浮动窗口：点它不会抢走前台，否则会被判定为离开目标页面。
            let panel = FocusPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = host
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            self.panel = panel
        }
        guard let panel else { return }
        // 换样式只改大小，保持左上角不动；第一次显示用上次拖到的位置，没有就放左上角。
        let topLeft: NSPoint
        if created || !panel.isVisible {
            topLeft = savedTopLeft(for: size) ?? defaultTopLeft(for: size)
        } else {
            topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
        if Headless.active { panel.alphaValue = 0; panel.ignoresMouseEvents = true }
        panel.orderFrontRegardless()
    }

    private func defaultTopLeft(for size: NSSize) -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSPoint(x: frame.minX + 14, y: frame.maxY - 14)
    }

    private func savedTopLeft(for size: NSSize) -> NSPoint? {
        guard let text = defaults.string(forKey: Prefs.focusPanelTopLeft) else { return nil }
        let point = NSPointFromString(text)
        let rect = NSRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
        // 保存的位置所在的屏幕还在才用。
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) } ? point : nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = panel?.frame, panel?.isVisible == true else { return }
        defaults.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Prefs.focusPanelTopLeft)
    }

    // MARK: 菜单栏

    private func showStatusItem() {
        showsMenuBarTimer = true
        guard !Headless.active else { return }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            let stop = menu.addItem(withTitle: "结束专注", action: #selector(stopFocus), keyEquivalent: "")
            stop.target = self
            let hide = menu.addItem(withTitle: "隐藏计时", action: #selector(hideTimer), keyEquivalent: "")
            hide.target = self
            item.menu = menu
            item.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "专注计时")
            item.button?.imagePosition = .imageLeading
            statusItem = item
        }
        updateStatusTitle()
    }

    private func removeStatusItem() {
        showsMenuBarTimer = false
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        button.attributedTitle = NSAttributedString(string: " " + FocusSession.clock(session.elapsed),
                                                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
        button.toolTip = session.active.map { "专注中：\($0.number.map { "#\($0) " } ?? "")\($0.title)" }
    }

    @objc private func stopFocus() { session.stop(reason: "手动结束") }
    @objc private func hideTimer() { defaults.set(true, forKey: Prefs.focusPanelHidden) }
}

struct FocusPanelView: View {
    @ObservedObject var session: FocusSession
    @AppStorage(Prefs.focusPanelStyle) private var styleName = FocusPanelStyle.card.rawValue
    @State private var hovering = false

    private var style: FocusPanelStyle { FocusPanelStyle(rawValue: styleName) ?? .card }

    var body: some View {
        if let active = session.active {
            Group {
                switch style {
                case .card, .menuBar: card(active)
                case .pill: pill
                case .digits: digits
                case .dot: dot
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }

    private var clock: String { FocusSession.clock(session.elapsed) }

    private func stopButton(size: CGFloat) -> some View {
        Button { session.stop(reason: "手动结束") } label: { Image(systemName: "stop.circle.fill").font(.system(size: size)) }
            .buttonStyle(.plain).foregroundStyle(Color.red).help("结束专注").accessibilityLabel("结束专注")
    }

    private func hideButton(size: CGFloat) -> some View {
        Button { UserDefaults.standard.set(true, forKey: Prefs.focusPanelHidden) } label: { Image(systemName: "eye.slash").font(.system(size: size)) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("隐藏计时（专注照常进行，\(HotKeyStore.binding(for: .focusPanel).label) 再次显示）").accessibilityLabel("隐藏计时")
    }

    private func card(_ active: FocusSession.Active) -> some View {
        HStack(spacing: 10) {
            Text(clock).font(.system(size: 20, weight: .semibold, design: .monospaced)).monospacedDigit()
            Text("\(active.number.map { "#\($0) " } ?? "")\(active.title)")
                .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            hideButton(size: 14)
            stopButton(size: 20)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14)))
        .padding(2)
    }

    private var pill: some View {
        HStack(spacing: 8) {
            Text(clock).font(.system(size: 15, weight: .medium, design: .monospaced)).monospacedDigit()
            Spacer(minLength: 0)
            hideButton(size: 11)
            stopButton(size: 15)
        }
        .padding(.horizontal, 12).frame(width: 148, height: 36)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .padding(2)
    }

    /// 没有底板的一行淡淡的数字；鼠标移上去才清晰，并出现按钮。
    private var digits: some View {
        HStack(spacing: 6) {
            Text(clock).font(.system(size: 13, weight: .regular, design: .monospaced)).monospacedDigit()
            if hovering {
                hideButton(size: 11)
                stopButton(size: 13)
            }
        }
        .foregroundStyle(.primary).opacity(hovering ? 0.95 : 0.4)
        .shadow(color: .black.opacity(0.35), radius: 1.5)
        .padding(.horizontal, 8).frame(width: 108, height: 30, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 平时只是一个小圆点；鼠标移上去展开成胶囊。
    private var dot: some View {
        ZStack(alignment: .leading) {
            if hovering {
                HStack(spacing: 8) {
                    Text(clock).font(.system(size: 13, weight: .medium, design: .monospaced)).monospacedDigit()
                    hideButton(size: 11)
                    stopButton(size: 13)
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                .transition(.opacity)
            } else {
                Circle().fill(Palette.success).frame(width: 7, height: 7).opacity(0.7).padding(.leading, 8)
            }
        }
        .frame(width: 132, height: 32, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 任务行上的播放键：有链接的任务才显示。
struct FocusPlayButton: View {
    @ObservedObject var session: FocusSession
    let task: ScheduledTask
    let url: URL

    private var running: Bool { session.active?.taskID == task.id }

    var body: some View {
        ItemActionButton(symbol: running ? "stop.circle.fill" : "play.circle",
                         title: running ? "结束专注计时" : "专注计时：打开链接并开始计时；离开页面自动停止") {
            if running { session.stop(reason: "手动结束") } else { session.start(task: task, url: url) }
        }
        .foregroundStyle(running ? Color.red : Palette.success)
    }
}

/// 任务行上的累计专注时长；这个任务正在计时时实时增长。
struct FocusTimeBadge: View {
    @ObservedObject var session: FocusSession
    let taskID: UUID
    let accumulated: TimeInterval

    var body: some View {
        let running = session.active?.taskID == taskID
        let total = accumulated + (running ? session.elapsed : 0)
        if total >= 1 || running {
            HStack(spacing: 3) {
                Image(systemName: running ? "timer" : "hourglass")
                Text(running ? FocusSession.clock(total) : FocusSession.brief(total)).monospacedDigit()
            }
            .foregroundStyle(running ? Palette.success : Palette.muted)
            .help("在这个任务上已累计专注 \(FocusSession.duration(total))")
            .accessibilityLabel("已专注 \(FocusSession.duration(total))")
        }
    }
}
