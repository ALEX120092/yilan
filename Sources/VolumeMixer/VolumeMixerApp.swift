import SwiftUI
import Combine

@main
struct VolumeMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns the status item directly (MenuBarExtra can't tell left from right clicks):
/// left click opens the mixer/status popover, right click opens the display-options menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let mixer = Mixer()
    private let stats = SystemStats()
    private let ai = AIUsage()
    private let awake = KeepAwake()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        stats.$menuBarItems
            .sink { [weak self] items in self?.ai.menuBarActive = !items.isDisjoint(with: [.claude, .codex]) }
            .store(in: &cancellables)
        mixer.objectWillChange.merge(with: stats.objectWillChange, ai.objectWillChange, awake.objectWillChange)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.updateStatusImage() }
            .store(in: &cancellables)
        updateStatusImage()
    }

    private func updateStatusImage() {
        statusItem.button?.image = menuBarStatsImage(items: stats.menuBarItems,
                                                     symbol: mixer.menuBarSymbol, stats: stats, ai: ai,
                                                     awake: awake.isActive)
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            showMenu()
        } else if event?.modifierFlags.contains(.option) == true {
            awake.toggle() // Option-click: quick keep-awake on/off, like Amphetamine
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // A fresh hosting controller per open, so onAppear/onDisappear start and stop sampling.
            let host = NSHostingController(rootView: PopoverView()
                .environmentObject(mixer).environmentObject(stats).environmentObject(ai).environmentObject(awake))
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        awake.stop() // releases the assertion and turns pmset disablesleep back off
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    // MARK: Right-click menu

    private func showMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for item in MenuBarItem.allCases {
            let entry = NSMenuItem(title: item.title, action: #selector(toggleMenuBarItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.rawValue
            entry.state = stats.menuBarItems.contains(item) ? .on : .off
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(awakeMenuItem())
        menu.addItem(.separator())
        let login = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = mixer.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出一览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // keep left click going to the popover
    }

    @objc private func toggleMenuBarItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let item = MenuBarItem(rawValue: raw) else { return }
        if stats.menuBarItems.contains(item) { stats.menuBarItems.remove(item) } else { stats.menuBarItems.insert(item) }
    }

    private func awakeMenuItem() -> NSMenuItem {
        var title = "保持唤醒"
        if awake.isActive { title += awake.endDate.map { "（剩余 \(awakeRemaining(until: $0))）" } ?? "（无限期）" }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.state = awake.isActive ? .on : .off
        let sub = NSMenu()
        for (index, option) in KeepAwake.durations.enumerated() {
            let entry = NSMenuItem(title: option.title, action: #selector(startAwake(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            sub.addItem(entry)
        }
        sub.addItem(.separator())
        let display = NSMenuItem(title: "允许屏幕关闭（仅阻止系统睡眠）", action: #selector(toggleAwakeDisplay), keyEquivalent: "")
        display.target = self
        display.state = awake.allowDisplaySleep ? .on : .off
        sub.addItem(display)
        let lid = NSMenuItem(title: awake.lidHelperInstalled ? "合盖也保持唤醒" : "合盖也保持唤醒（需安装辅助）…",
                             action: #selector(toggleAwakeLid), keyEquivalent: "")
        lid.target = self
        lid.state = awake.closedLid ? .on : .off
        sub.addItem(lid)
        if awake.lidHelperInstalled {
            let remove = NSMenuItem(title: "移除合盖辅助…", action: #selector(removeLidHelper), keyEquivalent: "")
            remove.target = self
            sub.addItem(remove)
        }
        if awake.isActive {
            sub.addItem(.separator())
            let stop = NSMenuItem(title: "停止", action: #selector(stopAwake), keyEquivalent: "")
            stop.target = self
            sub.addItem(stop)
        }
        item.submenu = sub
        return item
    }

    @objc private func startAwake(_ sender: NSMenuItem) {
        awake.start(for: KeepAwake.durations[sender.tag].seconds)
    }

    @objc private func stopAwake() { awake.stop() }

    @objc private func toggleAwakeDisplay() { awake.allowDisplaySleep.toggle() }

    @objc private func toggleAwakeLid() { awake.setClosedLid(!awake.closedLid) }

    @objc private func removeLidHelper() { awake.uninstallLidHelper() }

    @objc private func toggleLaunchAtLogin() {
        mixer.launchAtLogin.toggle()
    }
}

enum PopoverTab: String, CaseIterable {
    case volume = "音量"
    case status = "状态"
    case ai = "AI"
}

/// One menu bar item, two pages: the mixer and system status.
struct PopoverView: View {
    @EnvironmentObject private var mixer: Mixer
    @EnvironmentObject private var stats: SystemStats
    @EnvironmentObject private var ai: AIUsage
    @EnvironmentObject private var awake: KeepAwake
    @AppStorage("popoverTab") private var tab = PopoverTab.volume

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(PopoverTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            switch tab {
            case .volume:
                MixerView()
                    .onAppear { mixer.setVisible(true) }
                    .onDisappear { mixer.setVisible(false) }
            case .status:
                StatusView()
                    .onAppear { stats.setVisible(true) }
                    .onDisappear { stats.setVisible(false) }
            case .ai:
                AIView()
                    .onAppear { ai.setVisible(true) }
                    .onDisappear { ai.setVisible(false) }
            }

            Divider()
            awakeRow
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var awakeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .foregroundStyle(awake.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text("保持唤醒")
                Group {
                    if !awake.isActive {
                        Text(awake.stoppedForBattery ? "电量低于 \(percent(KeepAwake.lowBatteryCutoff))，已自动停止"
                                                     : "未开启 · " + modeText)
                    } else if let end = awake.endDate {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("剩余 \(awakeRemaining(until: end, now: context.date)) · " + modeText)
                        }
                    } else {
                        Text("无限期 · " + modeText)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(Array(KeepAwake.durations.enumerated()), id: \.offset) { _, option in
                    Button(option.title) { awake.start(for: option.seconds) }
                }
                Divider()
                Toggle("允许屏幕关闭（仅阻止系统睡眠）", isOn: $awake.allowDisplaySleep)
                Toggle(awake.lidHelperInstalled ? "合盖也保持唤醒" : "合盖也保持唤醒（需安装辅助）…",
                       isOn: Binding(get: { awake.closedLid }, set: { awake.setClosedLid($0) }))
            } label: {
                Text("时长")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Toggle("", isOn: Binding(get: { awake.isActive }, set: { $0 ? awake.start(for: nil) : awake.stop() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private var modeText: String {
        (awake.allowDisplaySleep ? "允许屏幕关闭" : "屏幕常亮") + (awake.closedLid ? " · 合盖" : "")
    }

    private var footer: some View {
        HStack {
            Toggle("登录时启动", isOn: $mixer.launchAtLogin)
                .toggleStyle(.checkbox)
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}

struct MixerView: View {
    @EnvironmentObject private var mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            outputSection
            Divider()
            appsSection
        }
    }

    // MARK: Sections

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("输出").font(.headline)
                Spacer()
                Picker("", selection: Binding(get: { mixer.defaultOutput },
                                              set: { mixer.selectOutput($0) })) {
                    ForEach(mixer.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            VolumeRow(
                icon: Image(systemName: "macbook.and.iphone"),
                iconIsSymbol: true,
                title: "系统音量",
                volume: Binding(get: { mixer.systemVolume }, set: { mixer.setSystemVolume($0) }),
                muted: mixer.systemMuted,
                isPlaying: false,
                onToggleMute: { mixer.setSystemMuted(!mixer.systemMuted) }
            )
            .disabled(!mixer.systemVolumeSettable)
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("应用").font(.headline)
            if mixer.apps.isEmpty {
                Text("当前没有应用在播放声音")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(mixer.apps) { app in
                            let setting = mixer.setting(for: app.id)
                            VolumeRow(
                                icon: Image(nsImage: app.icon),
                                iconIsSymbol: false,
                                title: app.name,
                                volume: Binding(get: { mixer.setting(for: app.id).volume },
                                                set: { mixer.setVolume($0, for: app.id) }),
                                muted: setting.muted,
                                isPlaying: app.isPlaying,
                                onToggleMute: { mixer.toggleMute(for: app.id) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct VolumeRow: View {
    let icon: Image
    let iconIsSymbol: Bool
    let title: String
    @Binding var volume: Float
    let muted: Bool
    let isPlaying: Bool
    let onToggleMute: () -> Void

    private var effective: Float { muted ? 0 : volume }

    private var speakerSymbol: String {
        if effective == 0 { return "speaker.slash.fill" }
        switch effective {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if iconIsSymbol {
                    icon.font(.system(size: 18)).foregroundStyle(.secondary)
                } else {
                    icon.resizable().interpolation(.high)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1).truncationMode(.tail)
                    if isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    Spacer(minLength: 4)
                    Text("\(Int((effective * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Button(action: onToggleMute) {
                        Image(systemName: speakerSymbol)
                            .frame(width: 18)
                            .foregroundStyle(muted ? .red : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(muted ? "取消静音" : "静音")

                    Slider(value: Binding(get: { Double(effective) },
                                          set: { volume = Float($0) }),
                           in: 0...1)
                        .controlSize(.small)
                }
            }
        }
    }
}
