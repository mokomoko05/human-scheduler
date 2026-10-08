import AppKit
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

// MARK: - 左上角的小计时窗口

private final class FocusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

@MainActor
final class FocusPanelController {
    private var panel: FocusPanel?
    private let session: FocusSession

    init(session: FocusSession) {
        self.session = session
        session.onActiveChange = { [weak self] active in active ? self?.show() : self?.hide() }
    }

    private func show() {
        if panel == nil {
            let host = NSHostingView(rootView: FocusPanelView(session: session))
            host.setFrameSize(NSSize(width: 254, height: 56))
            // 不激活的浮动窗口：点它不会抢走前台，否则会被判定为离开目标页面。
            let panel = FocusPanel(contentRect: NSRect(origin: .zero, size: host.frame.size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = host
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        if let panel, let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.minX + 14, y: frame.maxY - panel.frame.height - 14))
        }
        panel?.orderFrontRegardless()
    }

    private func hide() { panel?.orderOut(nil) }
}

struct FocusPanelView: View {
    @ObservedObject var session: FocusSession

    var body: some View {
        if let active = session.active {
            HStack(spacing: 10) {
                Text(FocusSession.clock(session.elapsed))
                    .font(.system(size: 20, weight: .semibold, design: .monospaced)).monospacedDigit()
                Text("\(active.number.map { "#\($0) " } ?? "")\(active.title)")
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                Button { session.stop(reason: "手动结束") } label: { Image(systemName: "stop.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain).foregroundStyle(Color.red).help("结束专注").accessibilityLabel("结束专注")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(width: 250)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14)))
            .padding(2)
        }
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
