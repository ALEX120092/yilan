import AppKit
import CoreAudio
import AudioToolbox
import ServiceManagement
import UniformTypeIdentifiers

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

struct AppSetting: Codable, Equatable {
    var volume: Float = 1
    var muted = false

    static let `default` = AppSetting()
    /// Perceptual curve: slider position squared.
    var gain: Float { muted ? 0 : volume * volume }
}

struct AudioApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    var processes: [AudioObjectID]
    var isPlaying: Bool
}

private struct Owner {
    let id: String
    let name: String
    let icon: NSImage
}

@MainActor
final class Mixer: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var defaultOutput = AudioObjectID(kAudioObjectUnknown)
    @Published private(set) var systemVolume: Float = 0
    @Published private(set) var systemMuted = false
    @Published private(set) var systemVolumeSettable = false
    @Published private(set) var settings: [String: AppSetting] = [:]
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("VolumeMixer: launch at login failed: \(error)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private var groups: [String: AudioApp] = [:]
    private var seen = Set<String>()
    private var taps: [String: AppTap] = [:]
    private var owners: [pid_t: Owner] = [:]
    private var systemListeners: [ListenerToken] = []
    private var deviceListeners: [ListenerToken] = []
    private var timer: Timer?
    private let ownPID = getpid()
    private static let settingsKey = "appSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved
        }

        let sys = AudioObjectID.system
        systemListeners = [
            sys.listen(kAudioHardwarePropertyProcessObjectList) { [weak self] in
                MainActor.assumeIsolated { self?.refreshApps() }
            },
            sys.listen(kAudioHardwarePropertyDevices) { [weak self] in
                MainActor.assumeIsolated { self?.refreshDevices() }
            },
            sys.listen(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                MainActor.assumeIsolated { self?.refreshDevices() }
            },
        ]

        refreshDevices()
        refreshApps()

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.taps.values.forEach { $0.invalidate() }
                self?.taps.removeAll()
            }
        }
    }

    // MARK: Popover visibility

    func setVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        refreshDevices()
        refreshApps()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshApps() }
        }
    }

    // MARK: System output

    var menuBarSymbol: String {
        if systemMuted || systemVolume == 0 { return "speaker.slash.fill" }
        switch systemVolume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    func setSystemVolume(_ value: Float) {
        systemVolume = value
        defaultOutput.set(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                          scope: kAudioObjectPropertyScopeOutput, Float32(value))
        if systemMuted, value > 0 { setSystemMuted(false) }
    }

    func setSystemMuted(_ muted: Bool) {
        systemMuted = muted
        defaultOutput.set(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, UInt32(muted ? 1 : 0))
    }

    func selectOutput(_ id: AudioObjectID) {
        AudioDevices.setDefaultOutput(id)
    }

    private func refreshDevices() {
        devices = AudioDevices.outputDevices()
        let current = AudioDevices.defaultOutput
        if current != defaultOutput {
            defaultOutput = current
            let out = kAudioObjectPropertyScopeOutput
            deviceListeners = [
                current.listen(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: out) { [weak self] in
                    MainActor.assumeIsolated { self?.readSystemVolume() }
                },
                current.listen(kAudioDevicePropertyMute, scope: out) { [weak self] in
                    MainActor.assumeIsolated { self?.readSystemVolume() }
                },
            ]
            syncTaps()
        }
        readSystemVolume()
    }

    private func readSystemVolume() {
        let out = kAudioObjectPropertyScopeOutput
        systemVolume = defaultOutput.get(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: out, default: Float32(0))
        systemMuted = defaultOutput.get(kAudioDevicePropertyMute, scope: out, default: UInt32(0)) != 0
        systemVolumeSettable = defaultOutput.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: out)
    }

    // MARK: Per-app volume

    func setting(for id: String) -> AppSetting { settings[id] ?? .default }

    func setVolume(_ volume: Float, for id: String) {
        var s = setting(for: id)
        s.volume = volume
        if volume > 0 { s.muted = false }
        update(s, for: id)
    }

    func toggleMute(for id: String) {
        var s = setting(for: id)
        s.muted.toggle()
        update(s, for: id)
    }

    private func update(_ setting: AppSetting, for id: String) {
        settings[id] = setting == .default ? nil : setting
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        syncTaps()
    }

    private func refreshApps() {
        var next: [String: AudioApp] = [:]
        var alive = Set<pid_t>()
        for object in AudioObjectID.system.getArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self) {
            let pid = object.get(kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid > 0, pid != ownPID else { continue }
            alive.insert(pid)
            let playing = object.get(kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            let owner = owner(of: pid)
            if var app = next[owner.id] {
                app.processes.append(object)
                app.isPlaying = app.isPlaying || playing
                next[owner.id] = app
            } else {
                next[owner.id] = AudioApp(id: owner.id, name: owner.name, icon: owner.icon,
                                          processes: [object], isPlaying: playing)
            }
        }
        owners = owners.filter { alive.contains($0.key) }

        for app in next.values where app.isPlaying { seen.insert(app.id) }
        groups = next
        apps = next.values
            .filter { seen.contains($0.id) || settings[$0.id] != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        syncTaps()
    }

    /// Creates, updates or removes taps so that exactly the apps with a non-default gain are tapped.
    private func syncTaps() {
        guard let outputUID = defaultOutput.getString(kAudioDevicePropertyDeviceUID) else { return }
        var wanted = Set<String>()
        for app in groups.values {
            let gain = setting(for: app.id).gain
            guard gain < 0.999 else { continue }
            wanted.insert(app.id)
            let processes = app.processes.sorted()
            if let tap = taps[app.id], tap.processes == processes, tap.outputUID == outputUID {
                tap.gain = gain
                continue
            }
            taps[app.id]?.invalidate()
            do {
                taps[app.id] = try AppTap(processes: processes, outputUID: outputUID, gain: gain)
            } catch {
                taps[app.id] = nil
                NSLog("VolumeMixer: tap for \(app.id) failed: \(error)")
            }
        }
        for (id, tap) in taps where !wanted.contains(id) {
            tap.invalidate()
            taps[id] = nil
        }
    }

    // MARK: Process → app resolution

    private func owner(of pid: pid_t) -> Owner {
        if let cached = owners[pid] { return cached }
        let resolved = resolveOwner(pid)
        owners[pid] = resolved
        return resolved
    }

    private func resolveOwner(_ pid: pid_t) -> Owner {
        // Helper processes (e.g. WebKit, Chrome renderers) report the app that launched them.
        let responsible = responsibility_get_pid_responsible_for_pid(pid)
        for candidate in [responsible, pid] where candidate > 0 {
            if let app = NSRunningApplication(processIdentifier: candidate),
               let bundleID = app.bundleIdentifier, app.bundleURL != nil {
                return Owner(id: bundleID, name: app.localizedName ?? bundleID,
                             icon: app.icon ?? NSWorkspace.shared.icon(for: .application))
            }
        }

        let path = Self.executablePath(responsible > 0 ? responsible : pid) ?? Self.executablePath(pid)
        if let path, let range = path.range(of: ".app/") {
            let appPath = String(path[..<range.lowerBound]) + ".app"
            let bundle = Bundle(path: appPath)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
            return Owner(id: bundle?.bundleIdentifier ?? appPath, name: name,
                         icon: NSWorkspace.shared.icon(forFile: appPath))
        }

        let name = path.map { ($0 as NSString).lastPathComponent } ?? "进程 \(pid)"
        return Owner(id: "proc." + name, name: name, icon: NSWorkspace.shared.icon(for: .unixExecutable))
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
