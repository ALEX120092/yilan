import AppKit
import ApplicationServices
import SwiftUI

/// A chat app watched on the 消息 page; only the installed ones are listed.
struct ChatApp: Identifiable, Equatable {
    let id: String // bundle identifier
    let name: String
    var url: URL
    var pid: pid_t?
    var badge: String? // Dock badge text, e.g. "3" or "99+"

    var running: Bool { pid != nil }
    var unread: Int { badge.flatMap { Int($0.filter(\.isNumber)) } ?? 0 }
}

/// Unread counts for WeChat, QQ and friends, read from each app's Dock badge through LaunchServices
/// (the same data `lsappinfo info -only StatusLabel` prints), so no permission is needed.
/// "原生菜单" presses the app's own menu bar icon via Accessibility, which does need permission.
@MainActor
final class MessageWatcher: ObservableObject {
    static let known: [(id: String, name: String)] = [
        ("com.tencent.xinWeChat", "微信"),
        ("com.tencent.qq", "QQ"),
        ("com.tencent.WeWorkMac", "企业微信"),
        ("com.alibaba.DingTalkMac", "钉钉"),
        ("com.bytedance.lark", "飞书"),
    ]

    @Published private(set) var apps: [ChatApp] = []
    @Published private(set) var axTrusted = AXIsProcessTrusted()

    var totalUnread: Int { apps.reduce(0) { $0 + $1.unread } }
    /// Some app shows a non-numeric badge (a dot) — unread, count unknown.
    var hasUnmarkedBadge: Bool { apps.contains { $0.badge?.isEmpty == false && $0.unread == 0 } }

    var menuBarActive = false { didSet { if menuBarActive != oldValue { reschedule() } } }
    private var pageVisible = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        apps = Self.known.compactMap { entry in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.id)
                .map { ChatApp(id: entry.id, name: entry.name, url: $0) }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func setVisible(_ visible: Bool) {
        pageVisible = visible
        reschedule()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard let interval: TimeInterval = pageVisible ? 1 : (menuBarActive ? 3 : nil) else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications
        var updated = apps
        for i in updated.indices {
            let pid = running.first { $0.bundleIdentifier == updated[i].id }?.processIdentifier
            updated[i].pid = pid
            updated[i].badge = pid.flatMap(Self.dockBadge)
        }
        if updated != apps { apps = updated }
        let trusted = AXIsProcessTrusted()
        if trusted != axTrusted { axTrusted = trusted }
    }

    // MARK: Actions

    /// Launches or brings the app forward; on a running app this also sends "reopen", so a closed main window comes back.
    func open(_ app: ChatApp) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config)
    }

    /// Clicks the app's own menu bar icon, opening its native panel or menu. Returns false if that wasn't possible.
    @discardableResult
    func pressMenuBarIcon(_ app: ChatApp) -> Bool {
        guard let pid = app.pid else { return false }
        guard AXIsProcessTrusted() else {
            requestAccessibility()
            return false
        }
        let element = AXUIElementCreateApplication(pid)
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &extras) == .success,
              let bar = extras else { return false }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let item = (children as? [AXUIElement])?.first else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        axTrusted = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Dock badge (private LaunchServices SPI, same source as lsappinfo)

    private typealias ASNCreate = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    private static let launchServices: (create: ASNCreate, copy: CopyItem)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW),
              let create = dlsym(handle, "_LSASNCreateWithPid"),
              let copy = dlsym(handle, "_LSCopyApplicationInformationItem") else { return nil }
        return (unsafeBitCast(create, to: ASNCreate.self), unsafeBitCast(copy, to: CopyItem.self))
    }()

    private static func dockBadge(pid: pid_t) -> String? {
        guard let ls = launchServices, let asn = ls.create(nil, pid)?.takeRetainedValue(),
              let value = ls.copy(-2 /* kLSDefaultSessionID */, asn, "StatusLabel" as CFString)?.takeRetainedValue(),
              let label = (value as? [String: Any])?["label"] as? String,
              !label.isEmpty else { return nil }
        return label
    }
}

// MARK: - Page

struct MessagesView: View {
    @EnvironmentObject private var messages: MessageWatcher
    /// Closes the popover before handing the click to another app's menu bar icon.
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("消息").font(.headline)
                Spacer()
                if messages.totalUnread > 0 {
                    Text("共 \(messages.totalUnread) 条未读")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if messages.apps.isEmpty {
                Text("没有找到微信、QQ 等聊天应用")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 10) {
                    ForEach(messages.apps) { row($0) }
                }
            }
            if !messages.axTrusted {
                HStack(alignment: .top, spacing: 10) {
                    RowIcon(symbol: "hand.raised")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("「原生菜单」需要辅助功能权限，用来点按应用自己的菜单栏图标。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("授权…") { messages.requestAccessibility() }
                            .controlSize(.small)
                    }
                }
            }
            Text("未读数取自程序坞角标：需在「系统设置 › 通知」里为该应用打开「标记」。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ app: ChatApp) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable().interpolation(.high)
                .frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) {
                    if let badge = app.badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.red))
                            .fixedSize()
                            .offset(x: 6, y: -4)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(status(app)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if app.running {
                Button {
                    dismiss()
                    // Let the popover go away first so the app's own panel isn't dismissed with it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if !messages.pressMenuBarIcon(app) { messages.open(app) }
                    }
                } label: {
                    Image(systemName: "menubar.arrow.down.rectangle")
                }
                .buttonStyle(.borderless)
                .help("原生菜单：点按\(app.name)自己的菜单栏图标")
            }
            Button(app.running ? "打开" : "启动") {
                dismiss()
                messages.open(app)
            }
            .controlSize(.small)
        }
    }

    private func status(_ app: ChatApp) -> String {
        guard app.running else { return "未运行" }
        guard let badge = app.badge else { return "没有未读" }
        return app.unread > 0 ? "\(badge) 条未读" : "有新消息"
    }
}
