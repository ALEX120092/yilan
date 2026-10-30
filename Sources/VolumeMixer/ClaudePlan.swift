import Foundation
import Security

struct PlanLimit {
    let key: String
    let name: String
    let percent: Double // 0...100
    let resetsAt: Date?
}

enum PlanStatus {
    case ok(limits: [PlanLimit], plan: String?)
    case noLogin
    case expired
    case failed(String)

    var fivePercent: Double? {
        guard case .ok(let limits, _) = self else { return nil }
        return limits.first { $0.key == "five_hour" }?.percent
    }
}

/// Claude subscription limits (the numbers `/usage` shows), fetched with Claude Code's own login.
/// The token is only read from the Keychain, never refreshed here: refreshing rotates it and would
/// sign Claude Code out. An expired token just means running the `claude` CLI once.
enum ClaudePlanClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async -> PlanStatus {
        guard let credentials = await Task.detached(priority: .utility, operation: readCredentials).value else {
            return .noLogin
        }
        if let expiry = credentials.expiresAt, expiry <= Date() { return .expired }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("VolumeMixer/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return .expired }
            guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("HTTP \(status)")
            }
            return .ok(limits: parse(json), plan: credentials.plan)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Every top-level object with a `utilization` field is a limit window
    /// (five_hour, seven_day, seven_day_opus, ...), so new windows show up without code changes.
    private static func parse(_ json: [String: Any]) -> [PlanLimit] {
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        return json.compactMap { key, value -> PlanLimit? in
            guard let w = value as? [String: Any],
                  let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return PlanLimit(key: key, name: name(for: key), percent: used,
                             resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
        }
        .sorted { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }
    }

    private static func name(for key: String) -> String {
        switch key {
        case "five_hour": return "5 小时限额"
        case "seven_day": return "每周限额"
        case "seven_day_opus": return "每周 Opus"
        case "seven_day_sonnet": return "每周 Sonnet"
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private struct Credentials: Sendable {
        let token: String
        let expiresAt: Date?
        let plan: String?
    }

    /// Blocks while macOS asks the user to allow access, so it runs off the main thread.
    @Sendable private static func readCredentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let expiry = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(token: token, expiresAt: expiry, plan: oauth["subscriptionType"] as? String)
    }
}
