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
    case unknown

    var displayName: String {
        switch self {
        case .glm:      return "GLM"
        case .deepseek: return "DeepSeek"
        case .unknown:  return "?"
        }
    }

    var menuTitle: String {
        switch self {
        case .glm:      return "GLM 配额"
        case .deepseek: return "DeepSeek 余额"
        case .unknown:  return "配额"
        }
    }

    var quitTitle: String {
        switch self {
        case .glm:      return "Quit QuotaPulse"
        case .deepseek: return "Quit QuotaPulse"
        case .unknown:  return "Quit QuotaPulse"
        }
    }
}

final class QuotaData {
    var windows: [QuotaWindow] = []
    var deepSeekBalance: DeepSeekBalance?
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

    private let glmAPIURL = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    private let deepSeekBalanceURL = URL(string: "https://api.deepseek.com/user/balance")!
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
        guard let key = resolveAPIKey() else { return nil }
        let providerName = detectCurrentProvider()?.lowercased() ?? ""
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
        case .unknown:
            menu.addItem(.sectionHeader(title: "未知 provider"))
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

// MARK: - App entry

let app = NSApplication.shared
let delegate = QuotaBarAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
