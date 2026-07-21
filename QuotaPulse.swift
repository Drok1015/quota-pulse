import Cocoa
import Foundation

// MARK: - Data model

struct QuotaWindow {
    let name: String
    let usedPct: Int
    let remainingPct: Int
    let resetsAt: String
}

// DeepSeek 余额 API 响应
struct DeepSeekBalance: Codable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

struct BalanceInfo: Codable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String
    let toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

struct KimiUsageRow {
    let name: String
    let used: Int
    let limit: Int
    let resetsAt: String?

    var remaining: Int { min(max(limit - used, 0), limit) }
    var remainingPct: Int {
        guard limit > 0 else { return 0 }
        return Int((Double(remaining) / Double(limit) * 100).rounded())
    }
    var usedPct: Int { 100 - remainingPct }
}

struct KimiCredential: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Double
    let scope: String?
    let tokenType: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scope
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

// GLM API 原始响应: { code, data: { limits: [...], level }, success }
struct APIResponse: Codable {
    let data: APIData?
}
struct APIData: Codable {
    let limits: [APILimit]
    let level: String?
}
struct APILimit: Codable {
    let type: String          // "TIME_LIMIT" | "TOKENS_LIMIT"
    let unit: Int?
    let number: Int?
    let percentage: Int       // 已用百分比
    let nextResetTime: Int64? // 毫秒时间戳
}

enum ProviderType {
    case glm
    case deepseek
    case kimi
    case unknown

    var displayName: String {
        switch self {
        case .glm:      return "GLM"
        case .deepseek: return "DeepSeek"
        case .kimi:     return "Kimi Code"
        case .unknown:  return "?"
        }
    }

    var menuTitle: String {
        switch self {
        case .glm:      return "GLM 配额"
        case .deepseek: return "DeepSeek 余额"
        case .kimi:     return "Kimi Code 额度"
        case .unknown:  return "配额"
        }
    }

    var quitTitle: String {
        switch self {
        case .glm:      return "Quit QuotaPulse"
        case .deepseek: return "Quit QuotaPulse"
        case .kimi:     return "Quit QuotaPulse"
        case .unknown:  return "Quit QuotaPulse"
        }
    }
}

final class QuotaData {
    var windows: [QuotaWindow] = []
    var deepSeekBalance: DeepSeekBalance?
    var kimiUsageRows: [KimiUsageRow] = []
    var providerType: ProviderType = .unknown
    var fetchedAt: Date = Date()
    var ok: Bool = false
}

// MARK: - App delegate

final class QuotaBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var displayTimer: Timer?
    private let quotaData = QuotaData()
    private var loginWindow: LoginWindowController?

    private let glmAPIURL = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    private let deepSeekBalanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private let kimiUsageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private let kimiOAuthTokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    private let kimiClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/.glm-quota-cache.json")
    private let refreshInterval: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        loadCache()
        updateDisplay()
        refresh(self)
        timer = Timer.scheduledTimer(timeInterval: refreshInterval,
                                       target: self,
                                       selector: #selector(refresh),
                                       userInfo: nil,
                                       repeats: true)
        // 每分钟刷新一次圆圈颜色（不重新请求 API）
        displayTimer = Timer.scheduledTimer(timeInterval: 60,
                                              target: self,
                                              selector: #selector(refreshDisplay),
                                              userInfo: nil,
                                              repeats: true)
    }

    // MARK: - Provider detection & API key resolution

    private func resolveAPIKey() -> String? {
        if let v = ProcessInfo.processInfo.environment["KIMI_API_KEY"], !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment["GLM_API_KEY"], !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment["ZHIPU_API_KEY"], !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !v.isEmpty { return v }
        return readKeyFromCodexDB()
    }

    /// 从 cc-switch 库读出当前 provider 名称
    private func detectCurrentProvider() -> String? {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db")
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return nil }
        let sql = "SELECT name FROM providers WHERE app_type='codex' AND is_current=1 LIMIT 1;"
        if let out = try? runSQLite(dbPath: dbPath.path, sql: sql) {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// 同时决定 provider 类型和对应的 API key
    private func resolveProviderAndKey() -> (provider: ProviderType, key: String)? {
        // 1. 手动配置优先（独立运行模式）
        if let manual = readManualConfig() {
            return (manual.provider, manual.key)
        }
        // 2. Kimi Code CLI 的 OAuth 登录可直接查询订阅额度
        if loadKimiCredential() != nil {
            return (.kimi, "")
        }
        // 2. 环境变量 / CC Switch 自动探测
        guard let key = resolveAPIKey() else { return nil }
        let providerName = detectCurrentProvider()?.lowercased() ?? ""
        if providerName.contains("kimi") || ProcessInfo.processInfo.environment["KIMI_API_KEY"] != nil {
            return (.kimi, key)
        }
        if providerName.contains("deepseek") {
            return (.deepseek, key)
        }
        if providerName.contains("zhipu") || providerName.contains("glm") {
            return (.glm, key)
        }
        // 无法判断时默认走 GLM 逻辑（向后兼容）
        return (.glm, key)
    }

    private func readKeyFromCodexDB() -> String? {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db")
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return nil }

        // 优先取当前 provider 的 key
        let sql = "SELECT json_extract(settings_config,'$.auth.OPENAI_API_KEY') " +
                 "FROM providers WHERE app_type='codex' AND is_current=1 LIMIT 1;"
        if let out = try? runSQLite(dbPath: dbPath.path, sql: sql) {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "null" { return trimmed }
        }
        // fallback: 找 zhipu
        let fallback = "SELECT json_extract(settings_config,'$.auth.OPENAI_API_KEY') " +
                       "FROM providers WHERE app_type='codex' AND name LIKE '%zhipu%' LIMIT 1;"
        if let out = try? runSQLite(dbPath: dbPath.path, sql: fallback) {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "null" { return trimmed }
        }
        return nil
    }

    private func runSQLite(dbPath: String, sql: String) throws -> String {
        let p = Pipe()
        let task = Process()
        task.launchPath = "/usr/bin/sqlite3"
        task.arguments = [dbPath, sql]
        task.standardOutput = p
        try task.run()
        task.waitUntilExit()
        return String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - Manual config (standalone mode)

    private var manualConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.quota-pulse-config.json")
    }

    private struct ManualConfig: Codable {
        let provider: String   // "glm" | "deepseek" | "kimi"
        let apiKey: String
    }

    private func readManualConfig() -> (provider: ProviderType, key: String)? {
        guard FileManager.default.fileExists(atPath: manualConfigURL.path),
              let data = try? Data(contentsOf: manualConfigURL),
              let cfg = try? JSONDecoder().decode(ManualConfig.self, from: data),
              (cfg.provider == "kimi" || !cfg.apiKey.isEmpty) else { return nil }
        let provider: ProviderType
        switch cfg.provider {
        case "deepseek": provider = .deepseek
        case "kimi":     provider = .kimi
        default:           provider = .glm
        }
        return (provider, cfg.apiKey)
    }

    private func saveManualConfig(provider: ProviderType, key: String) {
        let providerName: String
        switch provider {
        case .deepseek: providerName = "deepseek"
        case .kimi:     providerName = "kimi"
        default:        providerName = "glm"
        }
        let cfg = ManualConfig(provider: providerName, apiKey: key)
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        try? FileManager.default.createDirectory(
            at: manualConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: manualConfigURL, options: .atomic)
    }

    private func clearManualConfig() {
        try? FileManager.default.removeItem(at: manualConfigURL)
    }

    private var hasManualConfig: Bool {
        readManualConfig() != nil
    }

    // MARK: - Refresh

    /// 仅刷新界面显示（圆圈颜色），不重新拉取 API 数据
    @objc private func refreshDisplay() {
        updateDisplay()
    }

    @objc func refresh(_ sender: Any?) {
        guard let (provider, key) = resolveProviderAndKey() else {
            DispatchQueue.main.async { self.renderNoKey() }
            return
        }

        quotaData.providerType = provider

        switch provider {
        case .glm:
            fetchGLMQuota(key: key)
        case .deepseek:
            fetchDeepSeekBalance(key: key)
        case .kimi:
            fetchKimiUsage(key: key)
        case .unknown:
            fetchGLMQuota(key: key)
        }
    }

    private func fetchGLMQuota(key: String) {
        var req = URLRequest(url: glmAPIURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let resp = try? JSONDecoder().decode(APIResponse.self, from: data) else {
                DispatchQueue.main.async { self?.renderError() }
                return
            }
            self.quotaData.windows = self.convert(resp.data?.limits ?? [])
            self.quotaData.deepSeekBalance = nil
            self.quotaData.fetchedAt = Date()
            self.quotaData.ok = true
            self.saveCache(data: data)
            DispatchQueue.main.async { self.updateDisplay() }
        }
        task.resume()
    }

    private func fetchDeepSeekBalance(key: String) {
        var req = URLRequest(url: deepSeekBalanceURL)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let resp = try? JSONDecoder().decode(DeepSeekBalance.self, from: data) else {
                DispatchQueue.main.async { self?.renderError() }
                return
            }
            self.quotaData.windows = []
            self.quotaData.deepSeekBalance = resp
            self.quotaData.fetchedAt = Date()
            self.quotaData.ok = true
            DispatchQueue.main.async { self.updateDisplay() }
        }
        task.resume()
    }

    // MARK: - Kimi Code usage

    private var kimiCredentialURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/credentials/kimi-code.json")
    }

    private func loadKimiCredential() -> KimiCredential? {
        guard let data = try? Data(contentsOf: kimiCredentialURL) else { return nil }
        return try? JSONDecoder().decode(KimiCredential.self, from: data)
    }

    private func saveKimiCredential(_ credential: KimiCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        try? data.write(to: kimiCredentialURL, options: .atomic)
    }

    private func fetchKimiUsage(key: String) {
        // Kimi Code CLI stores a short-lived OAuth token locally. Refresh it before
        // querying so the menu-bar app shares the existing Kimi Code login.
        if key.isEmpty, let credential = loadKimiCredential() {
            if credential.expiresAt <= Date().timeIntervalSince1970 + 60 {
                refreshKimiCredential(credential) { [weak self] refreshed in
                    guard let self, let refreshed else {
                        DispatchQueue.main.async { self?.renderError() }
                        return
                    }
                    self.requestKimiUsage(accessToken: refreshed.accessToken)
                }
            } else {
                requestKimiUsage(accessToken: credential.accessToken)
            }
            return
        }
        guard !key.isEmpty else {
            DispatchQueue.main.async { self.renderNoKey() }
            return
        }
        requestKimiUsage(accessToken: key)
    }

    private func refreshKimiCredential(_ credential: KimiCredential,
                                       completion: @escaping (KimiCredential?) -> Void) {
        var request = URLRequest(url: kimiOAuthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Match Kimi Code CLI's OAuth client identity, including its persisted device ID.
        request.setValue("kimi_cli", forHTTPHeaderField: "X-Msh-Platform")
        if let deviceID = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/device_id"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !deviceID.isEmpty {
            request.setValue(deviceID, forHTTPHeaderField: "X-Msh-Device-Id")
        }
        request.httpBody = formData([
            "client_id": kimiClientID,
            "grant_type": "refresh_token",
            "refresh_token": credential.refreshToken,
        ])
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let refreshed = try? JSONDecoder().decode(KimiCredential.self, from: data) else {
                completion(nil)
                return
            }
            self.saveKimiCredential(refreshed)
            completion(refreshed)
        }.resume()
    }

    private func formData(_ values: [String: String]) -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = values.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return body.data(using: .utf8)
    }

    private func requestKimiUsage(accessToken: String) {
        var request = URLRequest(url: kimiUsageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { self?.renderError() }
                return
            }
            let rows = self.parseKimiUsage(payload)
            guard !rows.isEmpty else {
                DispatchQueue.main.async { self.renderError() }
                return
            }
            self.quotaData.windows = []
            self.quotaData.deepSeekBalance = nil
            self.quotaData.kimiUsageRows = rows
            self.quotaData.fetchedAt = Date()
            self.quotaData.ok = true
            DispatchQueue.main.async { self.updateDisplay() }
        }.resume()
    }

    private func parseKimiUsage(_ payload: [String: Any]) -> [KimiUsageRow] {
        var rows: [KimiUsageRow] = []
        if let limits = payload["limits"] as? [[String: Any]] {
            for (index, item) in limits.enumerated() {
                let detail = item["detail"] as? [String: Any] ?? item
                let window = item["window"] as? [String: Any] ?? [:]
                let name = kimiLimitName(item: item, detail: detail, window: window, index: index)
                if let row = makeKimiUsageRow(detail, fallbackName: name) {
                    rows.append(row)
                }
            }
        }
        // Kimi Code returns its overall membership cycle in `usage`; this is the 7-day quota.
        if let usage = payload["usage"] as? [String: Any],
           let row = makeKimiUsageRow(usage, fallbackName: "7d") {
            rows.append(row)
        }
        return rows
    }

    private func makeKimiUsageRow(_ data: [String: Any], fallbackName: String) -> KimiUsageRow? {
        guard let limit = intValue(data["limit"]) else { return nil }
        let used = intValue(data["used"])
            ?? ((intValue(data["remaining"]).map { limit - $0 }) ?? 0)
        let name = (data["name"] as? String) ?? (data["title"] as? String) ?? fallbackName
        return KimiUsageRow(name: name, used: used, limit: limit, resetsAt: kimiResetHint(data))
    }

    private func kimiLimitName(item: [String: Any], detail: [String: Any],
                               window: [String: Any], index: Int) -> String {
        for key in ["name", "title", "scope"] {
            if let value = (item[key] ?? detail[key]) as? String, !value.isEmpty { return value }
        }
        let duration = intValue(window["duration"] ?? item["duration"] ?? detail["duration"])
        let unit = (window["timeUnit"] ?? item["timeUnit"] ?? detail["timeUnit"]) as? String ?? ""
        if let duration {
            if unit.contains("MINUTE") { return duration >= 60 && duration % 60 == 0 ? "\(duration / 60)h" : "\(duration)m" }
            if unit.contains("HOUR") { return "\(duration)h" }
            if unit.contains("DAY") { return "\(duration)d" }
        }
        return "Limit #\(index + 1)"
    }

    private func kimiResetHint(_ data: [String: Any]) -> String? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            if let value = data[key] { return "resets at \(formatKimiResetTime(value))" }
        }
        for key in ["reset_in", "resetIn", "ttl"] {
            if let seconds = intValue(data[key]), seconds > 0 {
                return "resets in \(formatDuration(seconds))"
            }
        }
        return nil
    }

    private func formatKimiResetTime(_ value: Any) -> String {
        guard let value = value as? String else { return "\(value)" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return value }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd hh:mm:ss"
        return formatter.string(from: date)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 86_400 { return String(format: "%.1fd", Double(seconds) / 86_400) }
        if seconds >= 3_600 { return String(format: "%.1fh", Double(seconds) / 3_600) }
        return "\(seconds / 60)m"
    }

    // MARK: - Cache

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let resp = try? JSONDecoder().decode(APIResponse.self, from: data) else { return }
        quotaData.windows = convert(resp.data?.limits ?? [])
        quotaData.providerType = .glm
        quotaData.fetchedAt = Date()
    }

    private func saveCache(data: Data) {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: cacheURL)
    }

    // MARK: - Parse API limits → display windows (replicates glm-quota.sh)

    private func convert(_ limits: [APILimit]) -> [QuotaWindow] {
        let tokenLimits = limits
            .filter { $0.type == "TOKENS_LIMIT" }
            .sorted { ($0.nextResetTime ?? 0) < ($1.nextResetTime ?? 0) }
        guard !tokenLimits.isEmpty else { return [] }
        var result: [QuotaWindow] = []
        let first = tokenLimits[0]
        result.append(QuotaWindow(name: "5h", usedPct: first.percentage,
                                  remainingPct: 100 - first.percentage,
                                  resetsAt: fmtReset(first.nextResetTime)))
        if tokenLimits.count >= 2 {
            let last = tokenLimits[tokenLimits.count - 1]
            result.append(QuotaWindow(name: "7d", usedPct: last.percentage,
                                      remainingPct: 100 - last.percentage,
                                      resetsAt: fmtReset(last.nextResetTime)))
        }
        return result
    }

    private func fmtReset(_ tsMs: Int64?) -> String {
        guard let tsMs else { return "unknown" }
        let date = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000)
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        let diff = tsMs - Int64(Date().timeIntervalSince1970 * 1000)
        let suffix: String
        if diff < 3_600_000 {
            suffix = "\(diff / 60_000)m"
        } else if diff < 86_400_000 {
            suffix = String(format: "%.1fh", Double(diff) / 3_600_000)
        } else {
            suffix = String(format: "%.1fd", Double(diff) / 86_400_000)
        }
        return "\(df.string(from: date)) (\(suffix))"
    }

    // MARK: - Display

    private let barFontSize = NSFont.menuBarFont(ofSize: 0).pointSize

    // MARK: - Model switching (DeepSeek Flash / Pro)

    private var configTomlPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml").path
    }

    private func currentModelName() -> String {
        guard let content = try? String(contentsOfFile: configTomlPath, encoding: .utf8) else {
            return "unknown"
        }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model = ") {
                let value = trimmed.replacingOccurrences(of: "model = ", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                if value.hasSuffix("-flash") { return "flash" }
                if value.hasSuffix("-pro")   { return "pro" }
                return value
            }
        }
        return "unknown"
    }

    private func currentModelDisplayName() -> String {
        switch currentModelName() {
        case "flash": return "Flash"
        case "pro":   return "Pro"
        default:      return "Unknown"
        }
    }

    @objc private func toggleModel() {
        let current = currentModelName()
        let newModel = (current == "pro") ? "deepseek-v4-flash" : "deepseek-v4-pro"
        let task = Process()
        task.launchPath = "/usr/bin/sed"
        task.arguments = ["-i", "",
            "s/model = \"deepseek-v4-[^\"]*\"/model = \"\(newModel)\"/",
            configTomlPath]
        try? task.run()
        task.waitUntilExit()
        statusItem.menu = buildMenu()
    }
     
    /// 判断当前时间（Asia/Shanghai）是否在 DeepSeek 高峰时段
    /// 高峰：每日 9:00-12:00 和 14:00-18:00
    private func isPeakHour() -> Bool {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let hour = cal.component(.hour, from: Date())
        return (hour >= 9 && hour < 12) || (hour >= 14 && hour < 18)
    }

    private func peakCircleColor() -> NSColor {
        isPeakHour() ? .systemRed : .systemGreen
    }

    private func peakStatusText() -> String {
        isPeakHour() ? "高峰期（×2 计费）" : "非高峰期"
    }

    private func color(for pct: Int) -> NSColor {
        switch pct {
        case 0..<20: return .systemRed
        case 20..<50: return .systemYellow
        default: return .systemGreen
        }
    }

    private func colorForBalance(_ balance: Double) -> NSColor {
        switch balance {
        case ..<5:  return .systemRed
        case ..<20: return .systemYellow
        default:    return .systemGreen
        }
    }

    private func updateDisplay() {
        switch quotaData.providerType {
        case .glm:
            guard !quotaData.windows.isEmpty else { renderError(); return }
            let h5 = quotaData.windows[0]
            let d7 = quotaData.windows.count >= 2 ? quotaData.windows[1] : h5
            let title = "\(h5.usedPct)% / \(d7.usedPct)%"
            let minRemaining = min(h5.remainingPct, d7.remainingPct)
            statusItem.button?.attributedTitle = attributed(title, color: color(for: minRemaining))
        case .deepseek:
            guard let balance = quotaData.deepSeekBalance,
                  let info = balance.balanceInfos.first,
                  let total = Double(info.totalBalance) else {
                renderError()
                return
            }
            let circleColor = peakCircleColor()
            let circle = "\u{25CF}" // ●
            let title = String(format: "¥%.1f", total)
            let attrStr = NSMutableAttributedString()
            attrStr.append(NSAttributedString(string: circle + " ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: barFontSize, weight: .regular),
                .foregroundColor: circleColor,
            ]))
            attrStr.append(NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: barFontSize, weight: .regular),
                .foregroundColor: colorForBalance(total),
            ]))
            statusItem.button?.attributedTitle = attrStr
        case .kimi:
            guard !quotaData.kimiUsageRows.isEmpty else { renderError(); return }
            let h5 = quotaData.kimiUsageRows.first { $0.name == "5h" }
                ?? quotaData.kimiUsageRows.first!
            let d7 = quotaData.kimiUsageRows.first { $0.name == "7d" }
                ?? quotaData.kimiUsageRows.last!
            let title = "Kimi \(h5.usedPct)% / \(d7.usedPct)%"
            statusItem.button?.attributedTitle = attributed(title,
                color: color(for: min(h5.remainingPct, d7.remainingPct)))
        case .unknown:
            renderError()
        }
        statusItem.menu = buildMenu()
    }

    private func renderNoKey() {
        statusItem.button?.attributedTitle = attributed("no key", color: .systemRed)
        statusItem.menu = buildMenu()
    }

    private func renderError() {
        statusItem.button?.attributedTitle = attributed("—", color: .systemRed)
        statusItem.menu = buildMenu()
    }

    private func attributed(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: barFontSize, weight: .regular),
           .foregroundColor: color,
       ])
   }

    // MARK: - Account / login

    private func accountSectionTitle() -> String {
        if let manual = readManualConfig() {
            return "账号  \(manual.provider.displayName)"
        }
        return "未登录"
    }

    @objc func showLogin() {
        let defaultProvider: ProviderType = readManualConfig()?.provider
            ?? (resolveProviderAndKey()?.provider ?? .glm)
        let defaultKey: String? = readManualConfig()?.key
        loginWindow = LoginWindowController(
            defaultProvider: defaultProvider,
            defaultKey: defaultKey
        ) { [weak self] provider, key in
            guard let self else { return }
            self.saveManualConfig(provider: provider, key: key)
            self.loginWindow = nil
            self.refresh(nil)
        }
        loginWindow?.show()
    }

    @objc func logout() {
        clearManualConfig()
        refresh(nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "\(quotaData.providerType.menuTitle) Monitor"))
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        let fetched = "更新: " + df.string(from: quotaData.fetchedAt)
        menu.addItem(.sectionHeader(title: fetched))

        switch quotaData.providerType {
        case .glm:
            for w in quotaData.windows {
                let bar = makeBar(remaining: w.remainingPct)
                let title = "\(w.name)  \(bar) \(w.remainingPct)%   resets \(w.resetsAt)"
                menu.addItem(.sectionHeader(title: title))
            }
        case .deepseek:
            if let balance = quotaData.deepSeekBalance {
                // 高峰时段信息
                let peakStatus = peakStatusText()
                menu.addItem(.sectionHeader(title: "高峰计费  \(peakStatus)"))
                menu.addItem(.separator())
                for info in balance.balanceInfos {
                    let bar = makeBarForBalance(Double(info.totalBalance) ?? 0, maxBalance: 50)
                    menu.addItem(.sectionHeader(title: "余额  \(bar)  ¥\(info.totalBalance)"))
                    menu.addItem(.sectionHeader(title: "已充值  ¥\(info.toppedUpBalance)"))
                    menu.addItem(.sectionHeader(title: "已赠送  ¥\(info.grantedBalance)"))
                    menu.addItem(.sectionHeader(title: "状态  \(balance.isAvailable ? "可用" : "不可用")"))
                }
            }
            menu.addItem(.separator())
            let modelItem = NSMenuItem(title: "模型  \(currentModelDisplayName()) ▸  点击切换", action: #selector(toggleModel), keyEquivalent: "m")
            modelItem.target = self
            menu.addItem(modelItem)
        case .kimi:
            for row in quotaData.kimiUsageRows {
                let bar = makeBar(remaining: row.remainingPct)
                var title = "\(row.name)  \(bar) \(row.usedPct)% used   \(row.remainingPct)% left"
                if let resetsAt = row.resetsAt { title += "   \(resetsAt)" }
                menu.addItem(.sectionHeader(title: title))
            }
        case .unknown:
            menu.addItem(.sectionHeader(title: "未配置，请登录"))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: accountSectionTitle()))
        if hasManualConfig {
            let relogin = NSMenuItem(title: "重新登录", action: #selector(showLogin), keyEquivalent: "")
            relogin.target = self
            menu.addItem(relogin)
            let logoutItem = NSMenuItem(title: "退出登录", action: #selector(logout), keyEquivalent: "")
            logoutItem.target = self
            menu.addItem(logoutItem)
        } else {
            let loginItem = NSMenuItem(title: "登录配置 API Key", action: #selector(showLogin), keyEquivalent: "l")
            loginItem.target = self
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: quotaData.providerType.quitTitle,
                                  action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }

    private func makeBar(remaining: Int) -> String {
        let filled = remaining / 10
        let empty = 10 - filled
        return String(repeating: "█", count: max(0, filled)) + String(repeating: "░", count: max(0, empty))
    }

    private func makeBarForBalance(_ balance: Double, maxBalance: Double) -> String {
        let filled = min(10, max(0, Int(balance / maxBalance * 10)))
        let empty = 10 - filled
        return String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
    }
}

// MARK: - Login window

final class LoginWindowController: NSObject {
    private var window: NSWindow!
    private var providerPopup: NSPopUpButton!
    private var keyField: NSSecureTextField!
    private var hintLabel: NSTextField!
    private let onLogin: (ProviderType, String) -> Void

    init(defaultProvider: ProviderType,
         defaultKey: String?,
         onLogin: @escaping (ProviderType, String) -> Void) {
        self.onLogin = onLogin
        super.init()
        buildWindow(defaultProvider: defaultProvider, defaultKey: defaultKey)
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow(defaultProvider: ProviderType, defaultKey: String?) {
        let w: CGFloat = 380, h: CGFloat = 240
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "QuotaPulse 登录"
        window.isReleasedWhenClosed = false

        let view = window.contentView!
        let m: CGFloat = 20
        let fw = w - m * 2

        let titleLabel = NSTextField(labelWithString: "配置 API")
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.frame = NSRect(x: m, y: h - 34, width: fw, height: 20)
        view.addSubview(titleLabel)

        let providerLabel = NSTextField(labelWithString: "供应商")
        providerLabel.frame = NSRect(x: m, y: h - 66, width: fw, height: 16)
        view.addSubview(providerLabel)

        providerPopup = NSPopUpButton(frame: NSRect(x: m, y: h - 96, width: fw, height: 26),
                                      pullsDown: false)
        providerPopup.addItems(withTitles: ["GLM（智谱 BigModel）", "DeepSeek", "Kimi Code"])
        switch defaultProvider {
        case .deepseek: providerPopup.selectItem(at: 1)
        case .kimi:     providerPopup.selectItem(at: 2)
        default:        providerPopup.selectItem(at: 0)
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        view.addSubview(providerPopup)

        let keyLabel = NSTextField(labelWithString: "API Key")
        keyLabel.frame = NSRect(x: m, y: h - 130, width: fw, height: 16)
        view.addSubview(keyLabel)

        keyField = NSSecureTextField(frame: NSRect(x: m, y: h - 160, width: fw, height: 26))
        keyField.placeholderString = "粘贴你的 API Key"
        keyField.stringValue = defaultKey ?? ""
        keyField.drawsBackground = true
        keyField.bezelStyle = .roundedBezel
        view.addSubview(keyField)

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.frame = NSRect(x: m, y: h - 192, width: fw, height: 24)
        view.addSubview(hintLabel)
        updateHint()

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.frame = NSRect(x: w - m - 170, y: 16, width: 70, height: 30)
        cancelButton.keyEquivalent = "\u{1b}"
        view.addSubview(cancelButton)

        let loginButton = NSButton(title: "登录", target: self, action: #selector(confirmLogin))
        loginButton.frame = NSRect(x: w - m - 90, y: 16, width: 70, height: 30)
        loginButton.keyEquivalent = "\r"
        view.addSubview(loginButton)
    }

    private func currentProvider() -> ProviderType {
        switch providerPopup.indexOfSelectedItem {
        case 1: return .deepseek
        case 2: return .kimi
        default: return .glm
        }
    }

    @objc private func providerChanged() { updateHint() }

    private func updateHint() {
        switch currentProvider() {
        case .deepseek: hintLabel.stringValue = "在 platform.deepseek.com 用户中心获取"
        case .glm:      hintLabel.stringValue = "在 open.bigmodel.cn → API Keys 获取"
        case .kimi:     hintLabel.stringValue = "已登录 Kimi Code CLI 时会自动读取额度；也可粘贴 Kimi Code API Key"
        case .unknown:  hintLabel.stringValue = ""
        }
    }

    @objc private func confirmLogin() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = currentProvider()
        let hasKimiCLILogin = FileManager.default.fileExists(atPath:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".kimi/credentials/kimi-code.json").path)
        guard !key.isEmpty || (provider == .kimi && hasKimiCLILogin) else {
            NSSound.beep()
            return
        }
        window.orderOut(nil)
        onLogin(provider, key)
    }

    @objc private func cancel() {
        window.orderOut(nil)
    }
}

// MARK: - App entry

let app = NSApplication.shared
let delegate = QuotaBarAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
