import SwiftUI

struct AIView: View {
    @EnvironmentObject private var ai: AIUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            claudeSection
            Divider()
            codexSection
            footer
        }
    }

    // MARK: Claude

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Claude").font(.headline)
                if case .ok(_, let plan?)? = ai.plan {
                    Text(plan.uppercased())
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                Spacer()
                if ai.scanning && ai.lastScan == nil {
                    ProgressView().controlSize(.small)
                }
            }

            planRows

            if let block = ai.block {
                let now = Date()
                let elapsed = now.timeIntervalSince(block.start) / block.end.timeIntervalSince(block.start)
                StatRow(symbol: "clock", title: "当前 5 小时窗口",
                        value: "\(remaining(until: block.end)) 后重置", fraction: elapsed,
                        detail: "\(time(block.start))–\(time(block.end)) · \(block.totals.requests) 次请求 · \(compactTokens(block.totals.total)) tokens",
                        tint: .accentColor)
            } else {
                StatRow(symbol: "clock", title: "当前 5 小时窗口", value: "空闲", fraction: 0,
                        detail: "最近 5 小时内没有 Claude Code 请求")
            }

            HStack(alignment: .top, spacing: 10) {
                RowIcon(symbol: "sun.max")
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("今日")
                        Spacer()
                        Text("\(compactTokens(ai.today.total)) tokens")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(breakdown(ai.today))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    ForEach(ai.todayByModel, id: \.model) { entry in
                        HStack {
                            Text(entry.model)
                            Spacer()
                            Text("\(entry.totals.requests) 次 · \(compactTokens(entry.totals.total))")
                                .monospacedDigit()
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                RowIcon(symbol: "calendar")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("近 7 天")
                        Spacer()
                        Text("\(compactTokens(ai.week.total)) tokens · \(ai.week.requests) 次")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    DailyBars(days: ai.dailyTotals)
                }
            }
        }
    }

    @ViewBuilder
    private var planRows: some View {
        switch ai.plan {
        case .ok(let limits, _)?:
            ForEach(limits, id: \.key) { limit in
                StatRow(symbol: "gauge.with.dots.needle.50percent", title: limit.name,
                        value: "\(Int(limit.percent.rounded()))%", fraction: limit.percent / 100,
                        detail: limit.resetsAt.map { "\(remaining(until: $0)) 后重置 · \(dateTime($0))" } ?? "暂无重置时间")
            }
        case .expired?:
            notice("Claude 登录已过期：在终端运行一次 claude 即可刷新，套餐用量随后显示。")
        case .noLogin?:
            notice("未读取到 Claude Code 登录（需在钥匙串弹窗中允许访问）。")
        case .failed(let reason)?:
            notice("套餐用量获取失败：\(reason)")
        case nil:
            EmptyView()
        }
    }

    private func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RowIcon(symbol: "exclamationmark.circle")
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Codex

    @ViewBuilder
    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex").font(.headline)
                if let plan = ai.codex?.plan {
                    Text(plan.uppercased())
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
            }
            if let codex = ai.codex {
                ForEach(Array(codex.limits.enumerated()), id: \.offset) { _, limit in
                    let expired = limit.resetsAt <= Date()
                    StatRow(symbol: "gauge.with.dots.needle.33percent", title: windowName(limit.windowMinutes),
                            value: expired ? "已重置" : "\(Int(limit.usedPercent.rounded()))%",
                            fraction: expired ? 0 : limit.usedPercent / 100,
                            detail: expired ? "记录于 \(dateTime(codex.updated))，之后没有新记录"
                                            : "\(dateTime(limit.resetsAt)) 重置 · 记录于 \(dateTime(codex.updated))")
                }
            } else {
                Text("没有找到 Codex 会话记录")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        Text("套餐百分比来自 Anthropic（含 claude.ai 聊天）；token 统计仅本机 Claude Code 日志，含缓存读写。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Formatting

    private func breakdown(_ t: TokenTotals) -> String {
        "输出 \(compactTokens(t.output)) · 输入 \(compactTokens(t.input)) · 缓存写 \(compactTokens(t.cacheWrite)) · 缓存读 \(compactTokens(t.cacheRead))"
    }

    private func windowName(_ minutes: Int) -> String {
        switch minutes {
        case 300: return "5 小时限额"
        case 10080: return "每周限额"
        case let m where m % 1440 == 0: return "\(m / 1440) 天限额"
        case let m where m % 60 == 0: return "\(m / 60) 小时限额"
        default: return "限额"
        }
    }

    private func remaining(until date: Date) -> String {
        let m = max(0, Int(date.timeIntervalSinceNow / 60))
        if m >= 1440 { return "\(m / 1440) 天 \(m / 60 % 24) 小时" }
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    private func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    private func dateTime(_ d: Date) -> String { d.formatted(.dateTime.month().day().hour().minute()) }
}

private struct DailyBars: View {
    let days: [(day: Date, tokens: Int)]

    var body: some View {
        let peak = max(days.map(\.tokens).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, entry in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index == days.count - 1 ? Color.accentColor : Color.accentColor.opacity(0.45))
                        .frame(height: max(2, 30 * CGFloat(entry.tokens) / CGFloat(peak)))
                        .help("\(compactTokens(entry.tokens)) tokens")
                    Text(entry.day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 42, alignment: .bottom)
    }
}

/// 1234 → "1.2K", 28_451_103 → "28M"
func compactTokens(_ n: Int) -> String {
    let v = Double(n)
    switch v {
    case ..<1000: return "\(n)"
    case ..<1_000_000: return String(format: v < 10_000 ? "%.1fK" : "%.0fK", v / 1000)
    case ..<1_000_000_000: return String(format: v < 10_000_000 ? "%.1fM" : "%.0fM", v / 1_000_000)
    default: return String(format: "%.1fB", v / 1_000_000_000)
    }
}
