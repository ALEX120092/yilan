import Foundation
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration

struct BatteryInfo: Equatable {
    var level: Double          // 0...1
    var onAC: Bool
    var charging: Bool
    var minutesRemaining: Int? // to empty, or to full while charging
    var systemWatts: Double?   // whole-machine draw
    var batteryWatts: Double?  // + charging into the battery, − draining it
    var adapterWatts: Double?  // charger rating
}

/// Readouts that can be shown in the menu bar; picked from the status item's right-click menu.
enum MenuBarItem: String, CaseIterable {
    case volume, cpu, memory, disk, network, power, claude, codex

    static let systemItems: Set<MenuBarItem> = [.cpu, .memory, .disk, .network, .power]

    var title: String {
        switch self {
        case .volume: return "音量图标"
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        case .network: return "网络"
        case .power: return "电池与功率"
        case .claude: return "Claude 用量"
        case .codex: return "Codex 限额"
        }
    }
}

/// Samples CPU, memory, disk, network and battery: every second while the status page is visible,
/// every 2 s in the background while any readout is shown in the menu bar.
@MainActor
final class SystemStats: ObservableObject {
    static let historyLength = 60

    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuUser: Double = 0
    @Published private(set) var cpuSystem: Double = 0
    @Published private(set) var cpuHistory: [Double] = []

    @Published private(set) var memoryUsed: UInt64 = 0
    @Published private(set) var memoryCompressed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory

    @Published private(set) var diskTotal: Int64 = 0
    @Published private(set) var diskFree: Int64 = 0

    @Published private(set) var download: Double = 0 // bytes/s
    @Published private(set) var upload: Double = 0
    @Published private(set) var downloadHistory: [Double] = []
    @Published private(set) var uploadHistory: [Double] = []

    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var uptime: TimeInterval = 0

    private var timer: Timer?
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastNet: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastNetTime: Date?

    var memoryFraction: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) }
    var diskFraction: Double { diskTotal == 0 ? 0 : Double(diskTotal - diskFree) / Double(diskTotal) }

    @Published var menuBarItems: Set<MenuBarItem> = SystemStats.loadMenuBarItems() {
        didSet {
            UserDefaults.standard.set(menuBarItems.map(\.rawValue), forKey: Self.menuBarItemsKey)
            reschedule()
        }
    }
    private var pageVisible = false
    private let smc = SMC()
    private static let menuBarItemsKey = "menuBarItems"

    private static func loadMenuBarItems() -> Set<MenuBarItem> {
        guard let raw = UserDefaults.standard.stringArray(forKey: menuBarItemsKey) else {
            return [.volume, .cpu, .memory, .power]
        }
        return Set(raw.compactMap(MenuBarItem.init(rawValue:)))
    }

    init() { reschedule() }

    func setVisible(_ visible: Bool) {
        pageVisible = visible
        reschedule()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard let interval: TimeInterval = pageVisible ? 1 : (menuBarItems.isDisjoint(with: MenuBarItem.systemItems) ? nil : 2) else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleDisk()
        sampleNetwork()
        sampleBattery()
        uptime = ProcessInfo.processInfo.systemUptime
    }

    // MARK: CPU

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let t = info.cpu_ticks
        let now = (user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
        defer { lastTicks = now }
        guard let last = lastTicks else { return }

        let user = Double(now.user &- last.user + now.nice &- last.nice)
        let system = Double(now.system &- last.system)
        let idle = Double(now.idle &- last.idle)
        let total = user + system + idle
        guard total > 0 else { return }
        cpuUser = user / total
        cpuSystem = system / total
        cpu = cpuUser + cpuSystem
        Self.push(cpu, to: &cpuHistory)
    }

    // MARK: Memory

    private func sampleMemory() {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        // Same definition as Activity Monitor's "Memory Used": app + wired + compressed.
        let app = UInt64(vm.internal_page_count) &- UInt64(vm.purgeable_count)
        memoryCompressed = UInt64(vm.compressor_page_count) * page
        memoryUsed = (app + UInt64(vm.wire_count)) * page + memoryCompressed
    }

    // MARK: Disk

    private func sampleDisk() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else { return }
        diskTotal = Int64(total)
        diskFree = free
    }

    // MARK: Network

    private func sampleNetwork() {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return }
        defer { freeifaddrs(ifap) }

        // Count only the primary interface (like Stats), so VPN traffic isn't counted twice.
        let primary = Self.primaryInterface()
        var current: [String: (rx: UInt32, tx: UInt32)] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: ifa.ifa_name)
            if let primary, name != primary { continue }
            current[name] = (data.pointee.ifi_ibytes, data.pointee.ifi_obytes)
        }

        let now = Date()
        defer { lastNet = current; lastNetTime = now }
        guard let lastTime = lastNetTime else { return }
        let dt = now.timeIntervalSince(lastTime)
        guard dt > 0 else { return }

        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, c) in current {
            guard let l = lastNet[name] else { continue }
            // if_data counters are 32-bit; wrapping subtraction handles rollover.
            rx += UInt64(c.rx &- l.rx)
            tx += UInt64(c.tx &- l.tx)
        }
        download = Double(rx) / dt
        upload = Double(tx) / dt
        Self.push(download, to: &downloadHistory)
        Self.push(upload, to: &uploadHistory)
    }

    // MARK: Battery

    private func sampleBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            battery = nil
            return
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = desc[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            var info = BatteryInfo(
                level: Double(current) / Double(max),
                onAC: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                charging: charging,
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil
            )
            readPower(into: &info)
            battery = info
            return
        }
        battery = nil
    }

    /// Power figures: live SMC sensors when available, else the AppleSmartBattery registry entry
    /// (which the battery firmware only refreshes about once a minute).
    private func readPower(into info: inout BatteryInfo) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }

        // Amperage is a signed mA value that ioreg shows as unsigned; int64Value restores the sign.
        if let mV = (dict["Voltage"] as? NSNumber)?.int64Value,
           let mA = (dict["InstantAmperage"] as? NSNumber ?? dict["Amperage"] as? NSNumber)?.int64Value {
            info.batteryWatts = Double(mV * mA) / 1_000_000
        }
        if let telemetry = dict["PowerTelemetryData"] as? [String: Any],
           let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            info.systemWatts = load / 1000
        } else if let b = info.batteryWatts, b < 0 {
            info.systemWatts = -b
        }
        if let adapter = dict["AdapterDetails"] as? [String: Any],
           let watts = (adapter["Watts"] as? NSNumber)?.doubleValue, watts > 0 {
            info.adapterWatts = watts
        }

        // PSTR = total system power, PDTR = adapter input, PPBR = battery discharge rate (all watts).
        if let smc, let system = smc.float("PSTR"), system > 0 {
            info.systemWatts = system
            if let input = smc.float("PDTR"), input > 0 {
                info.batteryWatts = input - system
            } else if let discharge = smc.float("PPBR") {
                info.batteryWatts = -discharge
            }
        }
    }

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "VolumeMixer" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return global["PrimaryInterface"] as? String
    }

    private static func push(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}
