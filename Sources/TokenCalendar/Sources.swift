import CryptoKit
import Foundation

struct SourceReport: Sendable {
    let readings: [Reading]
    let issue: String?

    init(_ readings: [Reading], issue: String? = nil) {
        self.readings = readings
        self.issue = issue
    }
}

let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "TokenCalendar", directoryHint: .isDirectory)

extension Provider {
    func collect() async -> SourceReport {
        do {
            switch self {
            case .codex: return SourceReport(try collectCodex())
            case .cursor: return try await collectCursor()
            case .antigravity: return SourceReport(try collectAntigravity())
            }
        } catch {
            return SourceReport([], issue: error.localizedDescription)
        }
    }
}

private func localAccount(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func collectCodex() throws -> [Reading] {
    let cli = try executable("codex")
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let child = try Subprocess(cli, ["app-server", "--listen", "stdio://"], extra: [
        "PATH": cli.deletingLastPathComponent().path + ":" + path
    ])
    func send(_ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try child.write(String(decoding: data, as: UTF8.self) + "\n")
    }
    func messages(_ data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }
    }
    try send(["id": 1, "method": "initialize", "params": [
        "clientInfo": ["name": "token-calendar", "version": "0.1.0"]
    ]])
    let initial = try child.read(seconds: 7) { messages($0).contains { $0["id"] as? Int == 1 } }
    guard messages(initial).contains(where: { $0["id"] as? Int == 1 && $0["result"] != nil }) else {
        throw SourceError.output("Codex App Server 初始化失败")
    }
    try send(["method": "initialized"])
    try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
    try send(["id": 3, "method": "account/rateLimits/read"])
    let result = messages(try child.read(seconds: 14) { data in
        let ids = messages(data).compactMap { $0["id"] as? Int }
        return ids.contains(2) && ids.contains(3)
    })
    let accountResult = result.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any]
    let account = accountResult?["account"] as? [String: Any]
    let accountID = account?["email"].flatMap { ($0 as? String).map(localAccount) } ?? "local"
    guard let limits = result.first(where: { $0["id"] as? Int == 3 })?["result"] as? [String: Any] else {
        throw SourceError.output("Codex 未返回订阅额度，请检查 ChatGPT 登录")
    }
    var pools = limits["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
    if pools.isEmpty, let single = limits["rateLimits"] as? [String: Any] {
        pools[single["limitId"] as? String ?? "codex"] = single
    }
    let timestamp = Date()
    let readings = pools.flatMap { id, values in
        ["primary", "secondary"].compactMap { key -> Reading? in
            guard let window = values[key] as? [String: Any],
                  let minutes = window["windowDurationMins"] as? Int,
                  let used = window["usedPercent"] as? Double else { return nil }
            let period: Period
            switch minutes {
            case 300: period = .fiveHours
            case 10_080: period = .week
            default: return nil
            }
            let end = (window["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            return Reading(
                provider: .codex, account: accountID, pool: values["limitName"] as? String ?? (id == "codex" ? "Codex" : id),
                period: period, used: used, sampledAt: timestamp, startsAt: nil, resetsAt: end, approximate: false
            )
        }
    }
    guard !readings.isEmpty else { throw SourceError.output("Codex 未返回可用的配额窗口") }
    return readings
}

private final class RejectRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct CursorMonth: Decodable, Sendable {
    struct Plan: Decodable, Sendable {
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
    }

    let billingCycleStart: String
    let billingCycleEnd: String
    let planUsage: Plan?
}

private struct CursorWeek: Decodable, Sendable {
    let currentPeriodStart: String?
    let nextResetTimestampUtc: String?
    let usagePercent: Double?
}

private func collectCursor() async throws -> SourceReport {
    let credential = try Subprocess(URL(fileURLWithPath: "/usr/bin/security"), [
        "find-generic-password", "-s", "cursor-access-token", "-a", "cursor-user", "-w"
    ])
    credential.closeInput()
    let bytes = try credential.read(seconds: 12)
    let token = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let segments = token.split(separator: ".")
    guard segments.count == 3, token.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
        throw SourceError.auth
    }
    var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    let claims = Data(base64Encoded: payload).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    guard let subject = claims?["sub"] as? String else { throw SourceError.auth }
    let account = localAccount(subject)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 12
    configuration.timeoutIntervalForResource = 15
    let client = URLSession(configuration: configuration, delegate: RejectRedirect(), delegateQueue: nil)
    defer { client.finishTasksAndInvalidate() }

    @Sendable func request<T: Decodable & Sendable>(_ method: String, as: T.Type) async throws -> T {
        let uri = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!
        var request = URLRequest(url: uri)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let (data, response) = try await client.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 401 && status != 403 else { throw SourceError.auth }
        guard status == 200 else { throw SourceError.http(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func cursorTime(_ value: String) -> Date? {
        Double(value).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
    func isoTime(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    async let month = request("GetCurrentPeriodUsage", as: CursorMonth.self)
    async let week = request("GetSandUsageStatus", as: CursorWeek.self)
    let timestamp = Date()
    var readings: [Reading] = []
    var issues: [String] = []
    do {
        let value = try await month
        let pools = [("Cursor Models", value.planUsage?.autoPercentUsed), ("Other Models", value.planUsage?.apiPercentUsed)]
        for (name, optionalUsed) in pools {
            guard let used = optionalUsed else { continue }
            readings.append(Reading(
                provider: .cursor, account: account, pool: name, period: .month, used: used,
                sampledAt: timestamp, startsAt: cursorTime(value.billingCycleStart),
                resetsAt: cursorTime(value.billingCycleEnd), approximate: false
            ))
        }
        if readings.isEmpty { issues.append("Cursor 未返回个人月度额度") }
    } catch {
        issues.append(error.localizedDescription)
    }
    do {
        let value = try await week
        if let used = value.usagePercent {
            readings.append(Reading(
                provider: .cursor, account: account, pool: "Grok Bot", period: .week, used: used,
                sampledAt: timestamp, startsAt: isoTime(value.currentPeriodStart),
                resetsAt: isoTime(value.nextResetTimestampUtc), approximate: false
            ))
        }
    } catch {
        issues.append(error.localizedDescription)
    }
    let issue = issues.isEmpty ? nil : Array(Set(issues)).sorted().joined(separator: " · ")
    return SourceReport(readings, issue: issue)
}

private func collectAntigravity() throws -> [Reading] {
    let cli = try executable("agy")
    let folder = supportDirectory.appending(path: "Antigravity", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let child = try Subprocess(URL(fileURLWithPath: "/usr/bin/script"), [
        "-q", "/dev/null", "/bin/sh", "-c", #"/bin/stty rows 48 cols 150; exec "$@""#, "sh",
        cli.path, "--settings", #"{"altScreenMode":"always"}"#
    ], cwd: folder, extra: ["TERM": "xterm-256color"])
    let start = try child.read(seconds: 6) { data in
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("yes, i trust this folder") || text.contains("ask anything")
    }
    let startup = String(decoding: start, as: UTF8.self).lowercased()
    if startup.contains("yes, i trust this folder") {
        guard try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty else {
            throw SourceError.output("Antigravity 采样目录存在项目文件，请移走文件后重试")
        }
        try child.write("\r")
        _ = try child.read(seconds: 3)
    }
    try child.write("/usage")
    let selection = try child.read(seconds: 3) { data in
        String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("View model quota usage")
    }
    guard String(decoding: selection, as: UTF8.self).localizedCaseInsensitiveContains("View model quota usage") else {
        throw SourceError.output("Antigravity 未显示 /usage，请检查 CLI 登录和版本")
    }
    try child.write("\r")
    let raw = try child.read(seconds: 5)
    try? child.write("\u{001B}")
    _ = try? child.read(seconds: 0.15)
    try? child.write("\u{0003}")
    let readings = parseAntigravity(String(decoding: raw, as: UTF8.self), sampledAt: Date())
    guard !readings.isEmpty else { throw SourceError.output("Antigravity 未返回可用的额度面板") }
    return readings
}

func parseAntigravity(_ raw: String, sampledAt: Date) -> [Reading] {
    let clean = raw.replacingOccurrences(
        of: #"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[()][A-Z0-9]"#,
        with: "\n", options: .regularExpression
    )
    let percentage = #/^(\d+(?:\.\d+)?)%$/#
    let duration = #/^Refreshes in (?:(\d+)d\s*)?(?:(\d+)h\s*)?(?:(\d+)m)?$/#
    let decoration = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: " │┃║▏╭╮╰╯─━"))
    let lines = clean.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: decoration) }

    var pool: String?
    var period: Period?
    var remaining: Double?
    var latest: [String: Reading] = [:]
    var panelOpened = false
    for line in lines {
        if line.contains("Models & Quota") {
            panelOpened = true
            pool = nil
        }
        guard panelOpened else { continue }
        switch line.uppercased() {
        case "GEMINI MODELS": pool = "Gemini Models"
        case "CLAUDE AND GPT MODELS": pool = "Claude and GPT models"
        case "GEMINI 4 ARGON": pool = "Gemini 4 Argon"
        case "WEEKLY LIMIT REMAINING", "GEMINI 4 ARGON WEEKLY LIMIT":
            period = .week
            remaining = nil
        case "FIVE HOUR LIMIT REMAINING":
            period = .fiveHours
            remaining = nil
        default:
            if let match = line.wholeMatch(of: percentage) {
                remaining = Double(match.1)
            }
            let refresh = line.wholeMatch(of: duration)
            guard let pool, let period, let remaining,
                  refresh != nil || line == "Quota available" else { continue }
            let seconds = refresh.map {
                TimeInterval((Int($0.1 ?? "") ?? 0) * 86_400 + (Int($0.2 ?? "") ?? 0) * 3_600 + (Int($0.3 ?? "") ?? 0) * 60)
            }
            let reading = Reading(
                provider: .antigravity, account: "local", pool: pool, period: period, used: 100 - remaining,
                sampledAt: sampledAt, startsAt: nil, resetsAt: seconds.map { sampledAt + $0 }, approximate: true
            )
            latest[reading.id] = reading
        }
    }
    return Array(latest.values)
}
