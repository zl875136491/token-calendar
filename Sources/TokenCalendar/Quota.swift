import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case cursor = "Cursor"
    case antigravity = "Antigravity"

    var id: String { rawValue }
}

enum Period: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveHours = "5 小时"
    case week = "周"
    case month = "月"

    var id: String { rawValue }

    var duration: TimeInterval? {
        switch self {
        case .fiveHours: return 5 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return nil
        }
    }
}

struct Reading: Codable, Sendable {
    let provider: Provider
    let account: String
    let pool: String
    let period: Period
    let used: Double
    let sampledAt: Date
    let startsAt: Date?
    let resetsAt: Date?
    let approximate: Bool

    var id: String { [provider.rawValue, account, pool, period.rawValue].joined(separator: "/") }
    var start: Date? {
        startsAt ?? resetsAt.flatMap { end in period.duration.map { end - $0 } }
    }
}

struct ObservedWindow: Identifiable, Codable, Sendable {
    let id: UUID
    let trackedFrom: Date
    var startsAt: Date?
    var resetsAt: Date?
    var approximate: Bool
    var highestObserved: Double
    var lastObservedUsed: Double? = nil
    var byDay: [String: Double] = [:]

    var increase: Double { byDay.values.reduce(0, +) }
}

struct Meter: Identifiable, Codable, Sendable {
    var latest: Reading
    var windows: [ObservedWindow]
    var id: String { latest.id }
}

struct Ledger: Codable, Sendable {
    var meters: [String: Meter] = [:]

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    @discardableResult
    mutating func record(_ readings: [Reading]) -> Set<String> {
        var changed = Set<String>()
        for reading in readings where reading.used.isFinite && reading.used >= 0 {
            if var meter = meters[reading.id] {
                guard reading.sampledAt > meter.latest.sampledAt else { continue }
                update(&meter, with: reading)
                meters[reading.id] = meter
            } else {
                let window = makeWindow(reading, baseline: reading.used, since: reading.sampledAt)
                meters[reading.id] = Meter(latest: reading, windows: [window])
            }
            changed.insert(reading.id)
        }
        return changed
    }

    private func update(_ meter: inout Meter, with reading: Reading) {
        let previous = meter.latest
        let oldWindow = meter.windows[meter.windows.count - 1]
        let tolerance: TimeInterval = oldWindow.approximate || reading.approximate ? 120 : 1
        let movedReset: Bool
        if let oldEnd = oldWindow.resetsAt, let newEnd = reading.resetsAt {
            movedReset = abs(newEnd.timeIntervalSince(oldEnd)) > tolerance
        } else {
            movedReset = false
        }
        let expired = oldWindow.resetsAt.map { reading.sampledAt >= $0 } ?? false

        if movedReset || (expired && reading.resetsAt == nil && reading.used == 0) {
            let knownStart = reading.start.flatMap { start in
                let withinObservedPeriod = start >= previous.sampledAt && start <= reading.sampledAt
                return withinObservedPeriod && (expired || !reading.approximate) ? start : nil
            }
            let baseline = knownStart == nil ? reading.used : 0
            meter.windows.append(makeWindow(reading, baseline: baseline, since: knownStart ?? reading.sampledAt))
        } else {
            var window = oldWindow
            if window.startsAt == nil { window.startsAt = reading.start }
            if window.resetsAt == nil { window.resetsAt = reading.resetsAt }
            window.approximate = window.approximate || reading.approximate
            let delta = max(0, reading.used - window.highestObserved)
            if delta > 0 {
                window.byDay[Self.dayKey(reading.sampledAt), default: 0] += delta
            }
            window.highestObserved = max(window.highestObserved, reading.used)
            window.lastObservedUsed = reading.used
            meter.windows[meter.windows.count - 1] = window
        }
        meter.latest = reading
    }

    private func makeWindow(_ reading: Reading, baseline: Double, since: Date) -> ObservedWindow {
        var window = ObservedWindow(
            id: UUID(), trackedFrom: since, startsAt: reading.start, resetsAt: reading.resetsAt,
            approximate: reading.approximate, highestObserved: reading.used, lastObservedUsed: reading.used
        )
        if reading.used > baseline {
            window.byDay[Self.dayKey(reading.sampledAt)] = reading.used - baseline
        }
        return window
    }
}
