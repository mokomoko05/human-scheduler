import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var loginItem: LoginItem
    @ObservedObject private var themes = ThemeStore.shared
    let failedHotKeys: () -> Set<HotKeyAction>?
    @AppStorage(Prefs.hideCompleted) private var hideCompleted = false
    @AppStorage(Prefs.clickExpands) private var clickExpands = true
    @AppStorage(Prefs.weekStartsSunday) private var weekStartsSunday = false
    @AppStorage(Prefs.uiScale) private var uiScale = 1.0
    @AppStorage(Prefs.globalHotKey) private var globalHotKey = true
    @AppStorage(Prefs.terminalLayout) private var terminalLayout = TerminalLayout.threePanes.rawValue
    @AppStorage(Prefs.focusMinLogMinutes) private var focusMinLogMinutes = Prefs.defaultFocusMinLogMinutes

    var body: some View {
        Form {
            Section("日历与清单") {
                Picker("每周从", selection: $weekStartsSunday) {
                    Text("周一").tag(false)
                    Text("周日").tag(true)
                }.pickerStyle(.segmented)
                Toggle("单击日期时自动展开待办清单", isOn: $clickExpands)
                Text("关闭后，单击日期只选中它；双击或点标题栏的日期按钮再展开清单，日历不会随点击改变布局。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("隐藏已完成事项", isOn: $hideCompleted)
            }
            Section("配色") {
                ThemePicker(themes: themes)
            }
            Section("字号") {
                Picker("界面字号", selection: $uiScale) {
                    Text("标准").tag(1.0)
                    Text("较大 115%").tag(1.15)
                    Text("更大 130%").tag(1.3)
                }
            }
            Section("专注计时") {
                Stepper(value: $focusMinLogMinutes, in: 0...120) {
                    Text(focusMinLogMinutes == 0 ? "所有专注都记入日志" : "专注不足 \(focusMinLogMinutes) 分钟不记日志")
                }
                Text("手滑点了播放键、很快就结束的专注，不会在日志里留下「开始 / 结束」记录；用过的时间仍然累加到任务上。设为 0 则每次都记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("通用") {
                Toggle("登录时自动启动", isOn: Binding(get: { loginItem.enabled }, set: loginItem.setEnabled))
                Picker("新建终端的布局", selection: $terminalLayout) {
                    Text("三窗格：左边上下两格，右边一栏").tag(TerminalLayout.threePanes.rawValue)
                    Text("单窗格").tag(TerminalLayout.single.rawValue)
                }
                Toggle("启用全局快捷键", isOn: $globalHotKey)
                if globalHotKey {
                    ForEach(HotKeyAction.allCases) { HotKeyRecorder(action: $0) }
                    if let failed = failedHotKeys(), !failed.isEmpty {
                        Text("「\(failed.map(\.title).joined(separator: "」「"))」的组合已被其他应用占用，请换一个。")
                            .font(.caption).foregroundStyle(Palette.deadline)
                    }
                    Text("点组合框后直接按下想要的键（需要至少一个 ⌃ ⌥ ⌘）。在 Scheduler 或终端里再按一次就隐藏并回到刚才的应用；日志窗口里再按同一个键关闭，Tab 切换待办 / 日志（待办窗口按 Esc 关闭）；笔记窗口开着时再按一次关闭。菜单栏的叶子图标也能打开快速添加待办。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 780)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let loginItem: LoginItem
    private let failedHotKeys: () -> Set<HotKeyAction>?

    init(loginItem: LoginItem, failedHotKeys: @escaping () -> Set<HotKeyAction>?) {
        self.loginItem = loginItem
        self.failedHotKeys = failedHotKeys
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 780),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(loginItem: loginItem, failedHotKeys: failedHotKeys))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
