import Foundation

/// One assistant reply's token usage, as logged by Claude Code in ~/.claude/projects.
struct TokenRecord {
    let date: Date
    let model: String
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
    var total: Int { input + output + cacheWrite + cacheRead }
}

struct TokenTotals {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0, requests = 0
    var total: Int { input + output + cacheWrite + cacheRead }

    mutating func add(_ r: TokenRecord) {
        input += r.input; output += r.output; cacheWrite += r.cacheWrite; cacheRead += r.cacheRead; requests += 1
    }
}

/// Claude's usage limits reset on rolling 5-hour sessions; reconstructed from the logs the same way
/// ccusage does: a block starts at the hour of its first request and lasts 5 hours.
struct UsageBlock {
    let start: Date
    let end: Date
    var totals = TokenTotals()
    var lastActivity: Date
}

struct CodexLimit {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
}

struct CodexUsage {
    let limits: [CodexLimit]
    let plan: String?
    let updated: Date
}

/// Watches local AI tool logs: Claude Code token usage and Codex rate-limit snapshots.
@MainActor
final class AIUsage: ObservableObject {
    @Published private(set) var block: UsageBlock?
    @Published private(set) var today = TokenTotals()
    @Published private(set) var todayByModel: [(model: String, totals: TokenTotals)] = []
    @Published private(set) var week = TokenTotals()
    @Published private(set) var dailyTotals: [(day: Date, tokens: Int)] = [] // last 7 days, oldest first
    @Published private(set) var codex: CodexUsage?
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanning = false
    @Published private(set) var plan: PlanStatus?
    @Published private(set) var planFetchedAt: Date?
    private var planTask: Task<Void, Never>?

    var menuBarActive = false {
        didSet { if menuBarActive != oldValue { reschedule() } }
    }

    /// The tightest Codex window still in effect; nil once every logged window has reset.
    var codexCurrentPercent: Double? {
        codex?.limits.filter { $0.resetsAt > Date() }.map(\.usedPercent).max()
    }
    private var pageVisible = false
    fileprivate var pageVisibleForPlan: Bool { pageVisible }
    private var timer: Timer?
    private let scanner = ClaudeLogScanner()
    private let queue = DispatchQueue(label: "VolumeMixer.AIUsage", qos: .utility)

    func setVisible(_ visible: Bool) {
        pageVisible = visible
        reschedule()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard let interval: TimeInterval = pageVisible ? 15 : (menuBarActive ? 60 : nil) else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        refreshPlanIfStale()
        guard !scanning else { return }
        scanning = true
        let scanner = scanner
        queue.async {
            let records = scanner.scan()
            let codex = CodexReader.latest()
            let summary = Summary(records: records, now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.block = summary.block
                    self.today = summary.today
                    self.todayByModel = summary.todayByModel
                    self.week = summary.week
                    self.dailyTotals = summary.daily
                    self.codex = codex
                    self.lastScan = Date()
                    self.scanning = false
                }
            }
        }
    }
}

extension AIUsage {
    /// Plan limits change slowly and come from the network: at most every 2 min with the page open, 5 min otherwise.
    private func refreshPlanIfStale() {
        let maxAge: TimeInterval = pageVisibleForPlan ? 120 : 300
        if let last = planFetchedAt, Date().timeIntervalSince(last) < maxAge { return }
        guard planTask == nil else { return }
        planTask = Task { [weak self] in
            let status = await ClaudePlanClient.fetch()
            guard let self else { return }
            self.plan = status
            self.planFetchedAt = Date()
            self.planTask = nil
        }
    }
}

// MARK: - Aggregation

private struct Summary {
    var block: UsageBlock?
    var today = TokenTotals()
    var todayByModel: [(model: String, totals: TokenTotals)] = []
    var week = TokenTotals()
    var daily: [(day: Date, tokens: Int)] = []

    init(records: [TokenRecord], now: Date) {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let days = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: startOfToday) }
        var perDay = [Date: Int]()
        var perModel = [String: TokenTotals]()

        var current: UsageBlock?
        let blockLength: TimeInterval = 5 * 3600
        for r in records.sorted(by: { $0.date < $1.date }) {
            if r.date >= days[0] {
                week.add(r)
                perDay[cal.startOfDay(for: r.date), default: 0] += r.total
            }
            if r.date >= startOfToday {
                today.add(r)
                perModel[Self.shortModel(r.model), default: TokenTotals()].add(r)
            }
            if let b = current, r.date < b.end {
                current?.totals.add(r)
                current?.lastActivity = r.date
            } else {
                let start = cal.dateInterval(of: .hour, for: r.date)?.start ?? r.date
                var b = UsageBlock(start: start, end: start.addingTimeInterval(blockLength), lastActivity: r.date)
                b.totals.add(r)
                current = b
            }
        }
        if let b = current, now < b.end { block = b }
        todayByModel = perModel.map { ($0.key, $0.value) }.sorted { $0.totals.total > $1.totals.total }
        daily = days.map { ($0, perDay[$0] ?? 0) }
    }

    /// "claude-opus-5-5-20261001" → "Opus 5.5"
    static func shortModel(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        return ([family.prefix(1).uppercased() + family.dropFirst()] + [version.joined(separator: ".")])
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Claude Code logs

/// Incrementally reads ~/.claude/projects/**/*.jsonl: remembers each file's offset and only parses new lines.
/// Only touched from AIUsage's serial queue.
private final class ClaudeLogScanner: @unchecked Sendable {
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var offsets: [String: UInt64] = [:]
    private var records: [String: TokenRecord] = [:] // keyed by message id + request id (logs repeat replies)
    private let horizon: TimeInterval = 8 * 86400
    private let marker = Data("\"usage\"".utf8)
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func scan() -> [TokenRecord] {
        let cutoff = Date().addingTimeInterval(-horizon)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in files where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= cutoff,
                      let size = values.fileSize else { continue }
                read(url, size: UInt64(size))
            }
        }
        records = records.filter { $0.value.date >= cutoff }
        return Array(records.values)
    }

    private func read(_ url: URL, size: UInt64) {
        let path = url.path
        var offset = offsets[path] ?? 0
        if size < offset { offset = 0 } // file was rewritten
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }

        // Stop at the last complete line; a half-written line is picked up next time.
        var lineStart = data.startIndex
        while lineStart <= lastNewline, let end = data[lineStart...lastNewline].firstIndex(of: 0x0A) {
            let line = data[lineStart..<end]
            if line.range(of: marker) != nil { parse(line) }
            lineStart = end + 1
        }
        offsets[path] = offset + UInt64(lastNewline - data.startIndex + 1)
    }

    private func parse(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = obj["timestamp"] as? String,
              let date = formatter.date(from: stamp) else { return }
        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>" else { return }
        let key = "\(message["id"] as? String ?? UUID().uuidString)|\(obj["requestId"] as? String ?? "")"
        func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        records[key] = TokenRecord(date: date, model: model,
                                   input: n("input_tokens"), output: n("output_tokens"),
                                   cacheWrite: n("cache_creation_input_tokens"),
                                   cacheRead: n("cache_read_input_tokens"))
    }
}

// MARK: - Codex logs

/// Codex writes its server-reported rate limits into each session log as `token_count` events.
private enum CodexReader {
    static func latest() -> CodexUsage? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, d)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
        for (url, _) in newest {
            if let usage = lastRateLimits(in: url) { return usage }
        }
        return nil
    }

    private static func lastRateLimits(in url: URL) -> CodexUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in data.split(separator: 0x0A).reversed() where line.range(of: Data("rate_limits".utf8)) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let windows = ["primary", "secondary"].compactMap { key -> CodexLimit? in
                guard let w = limits[key] as? [String: Any],
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue,
                      let reset = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
                return CodexLimit(usedPercent: used, windowMinutes: (w["window_minutes"] as? NSNumber)?.intValue ?? 0,
                                  resetsAt: Date(timeIntervalSince1970: reset))
            }
            guard !windows.isEmpty else { continue }
            let updated = (obj["timestamp"] as? String).flatMap(formatter.date(from:)) ?? Date()
            return CodexUsage(limits: windows, plan: limits["plan_type"] as? String, updated: updated)
        }
        return nil
    }
}
