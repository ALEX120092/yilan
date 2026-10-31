import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var stats: SystemStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("系统").font(.headline)
                StatRow(symbol: "cpu", title: "CPU",
                        value: percent(stats.cpu), fraction: stats.cpu,
                        detail: "用户 \(percent(stats.cpuUser)) · 系统 \(percent(stats.cpuSystem))") {
                    Sparkline(series: [(stats.cpuHistory, Color.accentColor)], fixedMax: 1)
                }
                StatRow(symbol: "memorychip", title: "内存",
                        value: percent(stats.memoryFraction), fraction: stats.memoryFraction,
                        detail: "已用 \(bytes(stats.memoryUsed)) / \(bytes(stats.memoryTotal)) · 压缩 \(bytes(stats.memoryCompressed))")
                StatRow(symbol: "internaldrive", title: "磁盘",
                        value: percent(stats.diskFraction), fraction: stats.diskFraction,
                        detail: "可用 \(bytes(stats.diskFree)) / \(bytes(stats.diskTotal))")
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("网络").font(.headline)
                HStack(spacing: 10) {
                    RowIcon(symbol: "network")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 14) {
                            rate("arrow.down", stats.download, .blue)
                            rate("arrow.up", stats.upload, .red)
                            Spacer()
                        }
                        Sparkline(series: [(stats.downloadHistory, .blue), (stats.uploadHistory, .red)])
                    }
                }
            }

            if let battery = stats.battery {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("电池").font(.headline)
                    StatRow(symbol: batterySymbol(battery), title: batteryTitle(battery),
                            value: percent(battery.level), fraction: battery.level,
                            detail: batteryDetail(battery), tint: batteryTint(battery))
                }
            }

            HStack {
                Text("已运行 \(duration(stats.uptime))")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("右键菜单栏图标可选显示项")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .controlSize(.small)
        }
    }

    private func rate(_ symbol: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color).font(.caption.bold())
            Text("\(bytes(UInt64(value)))/s").monospacedDigit()
        }
    }

    // MARK: Battery text

    private func batterySymbol(_ b: BatteryInfo) -> String {
        if b.charging { return "battery.100percent.bolt" }
        switch b.level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func batteryTitle(_ b: BatteryInfo) -> String {
        b.charging ? "充电中" : (b.onAC ? "已接通电源" : "使用电池")
    }

    private func batteryDetail(_ b: BatteryInfo) -> String {
        var parts: [String] = []
        if let m = b.minutesRemaining {
            let t = String(format: "%d:%02d", m / 60, m % 60)
            parts.append(b.charging ? "\(t) 后充满" : "剩余 \(t)")
        } else {
            parts.append(b.charging || !b.onAC ? "正在估算…" : "未在充电")
        }
        if b.charging, let w = b.batteryWatts, w > 0 { parts.append("充电 \(watts(w))") }
        if let w = b.systemWatts { parts.append("功耗 \(watts(w))") }
        if b.onAC, let w = b.adapterWatts { parts.append("适配器 \(Int(w)) W") }
        return parts.joined(separator: " · ")
    }

    private func batteryTint(_ b: BatteryInfo) -> Color {
        if b.charging || b.onAC { return .green }
        return b.level < 0.2 ? .red : .accentColor
    }
}

// MARK: - Components

struct RowIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
    }
}

/// Same shape as the mixer's VolumeRow: icon, title + value, then a bar in place of the slider.
struct StatRow<Extra: View>: View {
    let symbol: String
    let title: String
    let value: String
    let fraction: Double
    let detail: String
    var tint: Color? = nil
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(spacing: 10) {
            RowIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                    Spacer(minLength: 4)
                    Text(value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                UsageBar(fraction: fraction, tint: tint ?? loadTint(fraction))
                Text(detail).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                extra()
            }
        }
    }

    private func loadTint(_ f: Double) -> Color {
        switch f {
        case ..<0.7: return .accentColor
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

extension StatRow where Extra == EmptyView {
    init(symbol: String, title: String, value: String, fraction: Double, detail: String, tint: Color? = nil) {
        self.init(symbol: symbol, title: title, value: value, fraction: fraction, detail: detail, tint: tint) { EmptyView() }
    }
}

struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

private struct Sparkline: View {
    let series: [([Double], Color)]
    var fixedMax: Double? = nil

    var body: some View {
        let peak = fixedMax ?? max(series.flatMap(\.0).max() ?? 0, 1)
        Canvas { ctx, size in
            let step = size.width / CGFloat(SystemStats.historyLength - 1)
            for (values, color) in series where values.count > 1 {
                var path = Path()
                let offset = CGFloat(SystemStats.historyLength - values.count) * step
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: offset + CGFloat(i) * step,
                                     y: size.height * (1 - CGFloat(min(v / peak, 1))))
                    i == 0 ? path.move(to: pt) : path.addLine(to: pt)
                }
                ctx.stroke(path, with: .color(color), lineWidth: 1.2)
            }
        }
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Menu bar label

/// Menu bar readout: the chosen items, grouped and separated by hairlines.
private struct MenuBarStatsLabel: View {
    let items: Set<MenuBarItem>
    let symbol: String
    let stats: SystemStats
    let ai: AIUsage
    let awake: Bool

    var body: some View {
        let groups: [[MenuBarItem]] = [[.volume], [.cpu, .memory, .disk], [.network], [.power], [.claude, .codex]]
            .map { $0.filter { items.contains($0) && ($0 != .power || stats.battery != nil) } }
            .filter { !$0.isEmpty }
        HStack(spacing: 5) {
            if awake { // keep-awake session indicator, always leftmost
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { separator }
                ForEach(group, id: \.self) { cell($0) }
            }
            if groups.isEmpty { cell(.volume) } // never leave the status item blank
        }
        .foregroundStyle(.black) // rendered as a template image, so the menu bar tints it
        .padding(.horizontal, 1)
        .frame(height: 22)
    }

    @ViewBuilder
    private func cell(_ item: MenuBarItem) -> some View {
        switch item {
        case .volume:
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 17)
        case .cpu:
            metric { Text("CPU") } value: { Text(percent(stats.cpu)) }
        case .memory:
            metric { Text("RAM") } value: { Text(percent(stats.memoryFraction)) }
        case .disk:
            metric { Text("SSD") } value: { Text(percent(stats.diskFraction)) }
        case .network:
            VStack(alignment: .leading, spacing: 0) {
                Text("↑ \(compactRate(stats.upload))")
                Text("↓ \(compactRate(stats.download))")
            }
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .frame(width: 54, alignment: .leading)
        case .power:
            if let battery = stats.battery { powerMetric(battery) }
        case .claude:
            metric(width: 36) { Text("CLAUDE") } value: { Text(ai.plan?.fivePercent.map { "\(Int($0.rounded()))%" }
                                                                 ?? ai.block.map { compactTokens($0.totals.total) } ?? "0") }
        case .codex:
            metric(width: 34) { Text("CODEX") } value: { Text(ai.codexCurrentPercent.map { "\(Int($0.rounded()))%" } ?? "—") }
        }
    }

    private var separator: some View {
        Rectangle().frame(width: 1, height: 13).opacity(0.3)
    }

    /// Stats-style stacked cell: tiny caption over a bold value, fixed width so the bar doesn't jitter.
    private func metric<C: View, V: View>(width: CGFloat = 31,
                                          @ViewBuilder caption: () -> C,
                                          @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            caption().font(.system(size: 7, weight: .medium)).fixedSize()
            value().font(.system(size: 11, weight: .semibold)).monospacedDigit().fixedSize()
        }
        .frame(width: width, alignment: .leading)
    }

    /// Caption is a battery gauge plus level; the value is charge power while charging, otherwise system draw.
    private func powerMetric(_ b: BatteryInfo) -> some View {
        metric(width: 38) {
            HStack(spacing: 2) {
                MiniBattery(level: b.level)
                Text(percent(b.level))
            }
        } value: {
            HStack(spacing: 0) {
                if b.charging, let w = b.batteryWatts, w > 0 {
                    Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                    Text(watts(w, compact: true))
                } else if b.onAC, b.systemWatts == nil {
                    Image(systemName: "powerplug.fill").font(.system(size: 8))
                } else {
                    Text(b.systemWatts.map { watts($0, compact: true) } ?? "—")
                }
            }
        }
    }
}

private struct MiniBattery: View {
    let level: Double

    var body: some View {
        HStack(spacing: 0.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.6).strokeBorder(lineWidth: 0.8)
                RoundedRectangle(cornerRadius: 0.6)
                    .frame(width: max(1, 8.6 * min(max(level, 0), 1)), height: 3.4)
                    .padding(.leading, 1.6)
            }
            .frame(width: 12, height: 6.6)
            RoundedRectangle(cornerRadius: 0.5).frame(width: 1, height: 2.6).opacity(0.6)
        }
    }
}

/// Status item image: the custom layout rasterized as a template so the menu bar tints it.
@MainActor
func menuBarStatsImage(items: Set<MenuBarItem>, symbol: String, stats: SystemStats, ai: AIUsage,
                       awake: Bool) -> NSImage {
    let renderer = ImageRenderer(content: MenuBarStatsLabel(items: items, symbol: symbol, stats: stats, ai: ai,
                                                            awake: awake))
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    let image = renderer.nsImage ?? NSImage()
    image.isTemplate = true
    return image
}

// MARK: - Formatting

func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

private func bytes<T: BinaryInteger>(_ n: T) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
}

private func watts(_ w: Double, compact: Bool = false) -> String {
    let n = w < 10 ? String(format: "%.1f", w) : String(format: "%.0f", w)
    return compact ? "\(n)W" : "\(n) W"
}

private func compactRate(_ bytesPerSecond: Double) -> String {
    let kb = bytesPerSecond / 1024
    if kb < 1000 { return String(format: kb < 10 ? "%.1f KB/s" : "%.0f KB/s", kb) }
    let mb = kb / 1024
    return String(format: mb < 10 ? "%.1f MB/s" : "%.0f MB/s", mb)
}

private func duration(_ t: TimeInterval) -> String {
    let m = Int(t) / 60
    let (d, h, min) = (m / 1440, m / 60 % 24, m % 60)
    return d > 0 ? "\(d) 天 \(h) 小时" : "\(h) 小时 \(min) 分"
}
