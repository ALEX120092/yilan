import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// Amphetamine-style "keep awake" sessions backed by an IOPM assertion: indefinite or timed,
/// either keeping the display on or only blocking idle system sleep (display may turn off).
/// Optional closed-lid mode flips `pmset disablesleep` through a narrow sudoers rule (see `LidHelper`).
@MainActor
final class KeepAwake: ObservableObject {
    static let durations: [(title: String, seconds: TimeInterval?)] = [
        ("无限期", nil), ("15 分钟", 15 * 60), ("30 分钟", 30 * 60), ("1 小时", 3600),
        ("2 小时", 2 * 3600), ("4 小时", 4 * 3600), ("8 小时", 8 * 3600),
    ]
    /// Closed-lid sessions end on their own below this battery level when not on AC.
    static let lowBatteryCutoff = 0.15

    @Published private(set) var isActive = false
    @Published private(set) var endDate: Date?
    @Published var allowDisplaySleep = UserDefaults.standard.bool(forKey: KeepAwake.displayKey) {
        didSet {
            UserDefaults.standard.set(allowDisplaySleep, forKey: Self.displayKey)
            if isActive { assert() } // swap the assertion type in place, keeping the end time
        }
    }
    @Published private(set) var closedLid = UserDefaults.standard.bool(forKey: KeepAwake.lidKey)
    @Published private(set) var lidHelperInstalled = LidHelper.isInstalled
    /// Set when a closed-lid session was cut short by the battery guard; cleared on the next start.
    @Published private(set) var stoppedForBattery = false

    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private var batteryTimer: Timer?
    private static let displayKey = "keepAwakeAllowDisplaySleep"
    private static let lidKey = "keepAwakeClosedLid"
    private static let sleepDisabledKey = "keepAwakeSleepDisabledByUs"

    init() {
        // A crash or force-quit mid-session would leave `disablesleep` on forever; undo it at launch.
        if UserDefaults.standard.bool(forKey: Self.sleepDisabledKey) { setSleepDisabled(false) }
    }

    /// Starts (or restarts) a session; `nil` means until stopped.
    func start(for seconds: TimeInterval?) {
        timer?.invalidate()
        timer = nil
        stoppedForBattery = false
        endDate = seconds.map { Date().addingTimeInterval($0) }
        if let seconds {
            timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
        assert()
        if assertionID == 0 { stop(); return }
        isActive = true
        applyLid()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        release()
        endDate = nil
        isActive = false
        applyLid()
    }

    func toggle() {
        if isActive { stop() } else { start(for: nil) }
    }

    /// Turning closed-lid mode on installs the helper first (one admin password prompt).
    func setClosedLid(_ on: Bool) {
        if on && !lidHelperInstalled {
            NSApp.activate()
            lidHelperInstalled = LidHelper.install()
            guard lidHelperInstalled else { return }
        }
        closedLid = on
        UserDefaults.standard.set(on, forKey: Self.lidKey)
        applyLid()
    }

    func uninstallLidHelper() {
        setSleepDisabled(false)
        NSApp.activate()
        LidHelper.uninstall()
        lidHelperInstalled = LidHelper.isInstalled
        if !lidHelperInstalled {
            closedLid = false
            UserDefaults.standard.set(false, forKey: Self.lidKey)
        }
    }

    // MARK: Closed lid

    private func applyLid() {
        let want = isActive && closedLid && lidHelperInstalled
        setSleepDisabled(want)
        batteryTimer?.invalidate()
        batteryTimer = nil
        guard want else { return }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBattery() }
        }
        checkBattery()
    }

    private func checkBattery() {
        guard let (level, onAC) = Self.battery(), !onAC, level < Self.lowBatteryCutoff else { return }
        NSLog("VolumeMixer: keep-awake stopped, battery at \(Int(level * 100))%")
        stop()
        stoppedForBattery = true
    }

    private func setSleepDisabled(_ on: Bool) {
        let wasOn = UserDefaults.standard.bool(forKey: Self.sleepDisabledKey)
        guard on != wasOn else { return } // never touch a disablesleep the user set by hand
        if LidHelper.setSleepDisabled(on) || !on {
            UserDefaults.standard.set(on, forKey: Self.sleepDisabledKey)
        }
    }

    private static func battery() -> (level: Double, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return (Double(cur) / Double(max), d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }

    // MARK: Assertion

    private func assert() {
        release()
        let type = allowDisplaySleep ? kIOPMAssertPreventUserIdleSystemSleep : kIOPMAssertPreventUserIdleDisplaySleep
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "一览：保持唤醒" as CFString, &assertionID)
        if result != kIOReturnSuccess {
            NSLog("VolumeMixer: keep-awake assertion failed: \(result)")
            assertionID = 0
        }
    }

    private func release() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}

/// Closed-lid sleep can only be blocked as root (`pmset -a disablesleep 1`). Rather than a privileged daemon,
/// a sudoers rule lets this user run exactly those two pmset commands without a password.
enum LidHelper {
    static let rulePath = "/etc/sudoers.d/yilan-pmset"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: rulePath) }

    /// Asks for an admin password once; the rule is checked with visudo before it goes live.
    static func install() -> Bool {
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let script = """
        set -e; f=$(/usr/bin/mktemp); printf '%s\\n' '\(rule)' > "$f"; \
        /usr/sbin/visudo -cf "$f" >/dev/null; /usr/sbin/chown root:wheel "$f"; /bin/chmod 440 "$f"; \
        /bin/mv "$f" '\(rulePath)'
        """
        return runAsAdmin(script) && isInstalled
    }

    static func uninstall() {
        _ = runAsAdmin("/usr/bin/pmset -a disablesleep 0; /bin/rm -f '\(rulePath)'")
    }

    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> Bool {
        guard isInstalled else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        if p.terminationStatus != 0 { NSLog("VolumeMixer: pmset disablesleep \(on) failed: \(p.terminationStatus)") }
        return p.terminationStatus == 0
    }

    private static func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"一览需要管理员权限来设置合盖保持唤醒。\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("VolumeMixer: admin script failed: \(error)") }
        return error == nil
    }
}

/// "1:05:09" / "12:34" countdown for the popover and menu.
func awakeRemaining(until end: Date, now: Date = Date()) -> String {
    let s = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}
