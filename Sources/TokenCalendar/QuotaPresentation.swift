import Foundation

struct WeeklyAllocation {
    let firstDay: Date
    let resetsAt: Date
    let percentagePerDay: Double

    func percentage(on day: Date) -> Double? {
        guard day >= firstDay, day < resetsAt else { return nil }
        return percentagePerDay
    }
}

struct TimelineBlock: Identifiable {
    let id: UUID
    let interval: DateInterval
    let visibleInterval: DateInterval
    let percentage: Double
    let remaining: Bool
    let approximate: Bool
}

struct QuotaPresentation {
    let meters: [Meter]
    let calendar: Calendar

    func pools(in period: Period) -> [Meter] {
        Provider.allCases.flatMap { pools(for: $0, period: period) }
    }

    func pools(for provider: Provider, period: Period) -> [Meter] {
        let matches = meters.filter { $0.latest.provider == provider && $0.latest.period == period }
        guard let account = matches.max(by: { $0.latest.sampledAt < $1.latest.sampledAt })?.latest.account else {
            return []
        }
        return matches.filter { $0.latest.account == account }.sorted {
            let order = ["Codex", "Cursor Models", "Other Models", "Gemini Models", "Claude and GPT models", "Gemini 4 Argon"]
            let left = order.firstIndex(of: $0.latest.pool) ?? order.count
            let right = order.firstIndex(of: $1.latest.pool) ?? order.count
            if left != right { return left < right }
            return $0.latest.pool.localizedStandardCompare($1.latest.pool) == .orderedAscending
        }
    }

    func weeklyAllocation(for meter: Meter, now: Date) -> WeeklyAllocation? {
        guard meter.latest.period == .week,
              let reset = meter.windows.last?.resetsAt ?? meter.latest.resetsAt,
              reset > now else { return nil }
        let firstDay = calendar.startOfDay(for: now)
        let resetDay = calendar.startOfDay(for: reset)
        let dateDifference = calendar.dateComponents([.day], from: firstDay, to: resetDay).day ?? 0
        let days = dateDifference + (reset > resetDay ? 1 : 0)
        guard days > 0 else { return nil }
        return WeeklyAllocation(
            firstDay: firstDay, resetsAt: reset, percentagePerDay: max(0, 100 - meter.latest.used) / Double(days)
        )
    }

    func dailyUsage(for meter: Meter) -> [String: Double] {
        meter.windows.reduce(into: [:]) { days, window in
            for (day, used) in window.byDay where used > 0 {
                days[day, default: 0] += used
            }
        }
    }

    func monthlyUsage(for meter: Meter, month: Date, now: Date, daily: [String: Double]) -> Double? {
        if calendar.isDate(month, equalTo: now, toGranularity: .month),
           meter.latest.resetsAt.map({ $0 > now }) ?? true {
            return meter.latest.used
        }
        let components = calendar.dateComponents([.year, .month], from: month)
        guard let year = components.year, let month = components.month else { return nil }
        let prefix = "\(year)-\(month)-"
        let total = daily.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
        return total > 0 ? total : nil
    }

    func timeBlocks(for meter: Meter, in day: DateInterval, now: Date) -> [TimelineBlock] {
        let dateKey = Ledger.dayKey(day.start, calendar: calendar)
        return meter.windows.enumerated().compactMap { index, window in
            guard let start = window.startsAt, var end = window.resetsAt else { return nil }
            if index + 1 < meter.windows.count {
                let next = meter.windows[index + 1]
                let nextStart = next.startsAt ?? next.trackedFrom
                if nextStart > start { end = min(end, nextStart) }
            }
            let visibleStart = max(start, day.start)
            let visibleEnd = min(end, day.end)
            guard visibleStart < visibleEnd else { return nil }
            let current = index == meter.windows.count - 1 && now >= visibleStart && now < visibleEnd
            let percentage: Double
            if current {
                percentage = max(0, 100 - meter.latest.used)
            } else {
                guard let used = window.byDay[dateKey], used > 0 else { return nil }
                percentage = used
            }
            return TimelineBlock(
                id: window.id,
                interval: DateInterval(start: start, end: end),
                visibleInterval: DateInterval(start: visibleStart, end: visibleEnd),
                percentage: percentage, remaining: current, approximate: window.approximate
            )
        }.sorted { $0.visibleInterval.start < $1.visibleInterval.start }
    }
}
