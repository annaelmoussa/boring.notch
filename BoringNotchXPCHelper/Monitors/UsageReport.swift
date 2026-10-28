//
//  UsageReport.swift
//  BoringNotchXPCHelper
//
//  Plan usage of the agents' providers, gathered only when the notch asks for it:
//  Claude from its status line relay, Codex from its own session logs, and, if enabled,
//  the OpenRouter credit balance.
//

import Foundation

enum UsageReport {
    /// Replies with `{"providers": [{"name", "windows": [{"label", "percent", "resetsAt"}]} | {"name", "balance"}]}`.
    static func build(claudeRateLimits: [String: Any], includeOpenRouter: Bool, reply: @escaping (Data?) -> Void) {
        var providers: [[String: Any]] = []
        let claude = windows([("five_hour", "5h"), ("seven_day", "Week")].compactMap { key, label in
            (claudeRateLimits[key] as? [String: Any]).map { ($0, "used_percentage", label) }
        })
        if !claude.isEmpty { providers.append(["name": "Claude", "windows": claude]) }
        if let codex = codexWindows(), !codex.isEmpty { providers.append(["name": "Codex", "windows": codex]) }

        let finish = { (balance: Double?) in
            if let balance { providers.append(["name": "OpenRouter", "balance": balance]) }
            reply(try? JSONSerialization.data(withJSONObject: ["providers": providers]))
        }
        includeOpenRouter ? openRouterBalance(completion: finish) : finish(nil)
    }

    /// Normalises rate limit windows: `{<percent key>, "resets_at", "window_minutes"?}`, labelled from
    /// their length when known. A window that has already reset is reported empty.
    private static func windows(_ limits: [(window: [String: Any], percentKey: String, label: String)]) -> [[String: Any]] {
        let now = Date().timeIntervalSince1970
        return limits.compactMap { window, percentKey, label in
            guard let percent = window[percentKey] as? Double else { return nil }
            let resetsAt = window["resets_at"] as? Double
            let isCurrent = resetsAt.map { $0 > now } ?? true
            let minutes = window["window_minutes"] as? Double
            let name = minutes.map { $0 >= 7 * 24 * 60 ? "Week" : "\(Int($0 / 60))h" } ?? label
            var result: [String: Any] = ["label": name, "percent": isCurrent ? percent : 0]
            if isCurrent { result["resetsAt"] = resetsAt }
            return result
        }
    }

    // MARK: - Codex

    private static let codexSessions = NSHomeDirectory() + "/.codex/sessions"

    /// Codex records its rate limits in the session log after every turn; the latest log has the latest values.
    private static func codexWindows() -> [[String: Any]]? {
        guard let log = latestCodexLog(), let handle = FileHandle(forReadingAtPath: log) else { return nil }
        defer { try? handle.close() }
        // The values sit near the end; reading the last 256 KB is enough and keeps this cheap.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.contains("\"rate_limits\"") }),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let limits = find("rate_limits", in: object) as? [String: Any]
        else { return nil }
        return windows([("primary", "5h"), ("secondary", "Week")].compactMap { key, label in
            (limits[key] as? [String: Any]).map { ($0, "used_percent", label) }
        })
    }

    /// Logs are stored as `sessions/<year>/<month>/<day>/rollout-….jsonl`.
    private static func latestCodexLog() -> String? {
        var directory = codexSessions
        for _ in 0 ..< 3 {
            guard let latest = (try? FileManager.default.contentsOfDirectory(atPath: directory))?.filter({ !$0.hasPrefix(".") }).max() else { return nil }
            directory += "/" + latest
        }
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: directory))?.filter { $0.hasSuffix(".jsonl") } ?? []
        return logs.map { directory + "/" + $0 }.max { modificationDate($0) < modificationDate($1) }
    }

    private static func modificationDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    private static func find(_ key: String, in object: Any) -> Any? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let value = dictionary[key] { return value }
        return dictionary.values.lazy.compactMap { find(key, in: $0) }.first
    }

    // MARK: - OpenRouter

    private static let lock = NSLock()
    private static var cachedBalance: (date: Date, value: Double)?
    private static let cacheLifetime: TimeInterval = 5 * 60

    /// The remaining credit, using the OpenRouter key already saved by Pi or OpenCode.
    private static func openRouterBalance(completion: @escaping (Double?) -> Void) {
        if let cached = lock.withLock({ cachedBalance }), Date().timeIntervalSince(cached.date) < cacheLifetime {
            return completion(cached.value)
        }
        fetchBalance(keys: openRouterKeys(), completion: completion)
    }

    private static func fetchBalance(keys: [String], completion: @escaping (Double?) -> Void) {
        guard let key = keys.first else { return completion(nil) }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/credits")!, timeoutInterval: 10)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let credits = object["data"] as? [String: Any],
                  let total = credits["total_credits"] as? Double, let used = credits["total_usage"] as? Double
            else { return fetchBalance(keys: Array(keys.dropFirst()), completion: completion) }
            lock.withLock { cachedBalance = (Date(), total - used) }
            completion(total - used)
        }.resume()
    }

    private static func openRouterKeys() -> [String] {
        ["/.pi/agent/auth.json", "/.local/share/opencode/auth.json"].compactMap { path in
            guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (object["openrouter"] as? [String: Any])?["key"] as? String
        }
    }
}
