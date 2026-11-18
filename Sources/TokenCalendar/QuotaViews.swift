import SwiftUI

extension Provider {
    var color: Color {
        switch self {
        case .codex: return Color(red: 0.31, green: 0.52, blue: 0.93)
        case .cursor: return Color(red: 0.86, green: 0.50, blue: 0.22)
        case .antigravity: return Color(red: 0.17, green: 0.62, blue: 0.51)
        }
    }
}

extension Meter {
    var shortPoolName: String {
        switch latest.pool {
        case "Gemini Models": return "Gemini"
        case "Claude and GPT models": return "Claude / GPT"
        case "Gemini 4 Argon": return "Argon"
        default: return latest.pool
        }
    }

    var tint: Color {
        switch latest.pool {
        case "Claude and GPT models": return Color(red: 0.19, green: 0.66, blue: 0.66)
        case "Gemini 4 Argon": return Color(red: 0.38, green: 0.77, blue: 0.61)
        case "Other Models": return Color(red: 0.92, green: 0.65, blue: 0.30)
        default: return latest.provider.color
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [tint.opacity(0.72), tint], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

func quotaPercent(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2))) + "%"
}

private func fillFraction(_ percentage: Double) -> CGFloat {
    CGFloat(min(100, max(0, percentage)) / 100)
}

private struct QuotaColumns: View {
    let meters: [Meter]
    let values: [String: Double]
    let height: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            ForEach(meters) { meter in
                if let value = values[meter.id] {
                    column(meter, value: value)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height + 16)
    }

    private func column(_ meter: Meter, value: Double) -> some View {
        let compact = values.count >= 4
        let label = compact
            ? (value > 0 && value < 0.5 ? "<1%" : value.formatted(.number.precision(.fractionLength(0))) + "%")
            : quotaPercent(value)
        return VStack(spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(meter.tint)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.64)
                .frame(maxWidth: .infinity)
                .frame(height: 13)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(meter.tint.opacity(0.11))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(meter.tint.opacity(0.34), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                if value > 0 {
                    Rectangle().fill(meter.gradient).frame(height: max(1, height * fillFraction(value)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(height: height)
        }
        .help("\(meter.latest.pool) · \(quotaPercent(value))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.latest.pool)
        .accessibilityValue(quotaPercent(value))
    }
}

struct WeekCalendar: View {
    let month: Date
    let presentation: QuotaPresentation
    let meters: [Meter]

    private var calendar: Calendar { presentation.calendar }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    private var days: [Date] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let total = ((count + leading + 6) / 7) * 7
        return (0..<total).compactMap { calendar.date(byAdding: .day, value: $0 - leading, to: start) }
    }

    var body: some View {
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let histories = Dictionary(uniqueKeysWithValues: meters.map { ($0.id, presentation.dailyUsage(for: $0)) })
        let allocations = Dictionary(uniqueKeysWithValues: meters.compactMap { meter in
            presentation.weeklyAllocation(for: meter, now: now).map { (meter.id, $0) }
        })
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { weekday in
                    Text(weekday)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 3)
                }
                ForEach(days, id: \.self) { day in
                    let values = day < today
                        ? histories.compactMapValues { $0[Ledger.dayKey(day, calendar: calendar)] }
                        : allocations.compactMapValues { $0.percentage(on: day) }
                    dayCell(day, values: values, now: now)
                }
            }
            .padding(.bottom, 18)
        }
    }

    private func dayCell(_ day: Date, values: [String: Double], now: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let today = calendar.isDate(day, inSameDayAs: now)
        return VStack(alignment: .leading, spacing: 6) {
            Text(String(calendar.component(.day, from: day)))
                .font(.system(size: 12, weight: today ? .bold : .medium).monospacedDigit())
                .foregroundStyle(today ? Color.accentColor : inMonth ? Color.primary : Color.secondary)
            QuotaColumns(meters: meters, values: values, height: 39)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(inMonth ? Color.primary.opacity(0.04) : Color.primary.opacity(0.02),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if today {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }
}

struct MonthMatrix: View {
    let year: Date
    let presentation: QuotaPresentation
    let meters: [Meter]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        let calendar = presentation.calendar
        let yearStart = calendar.dateInterval(of: .year, for: year)?.start ?? year
        let now = Date()
        let histories = Dictionary(uniqueKeysWithValues: meters.map { ($0.id, presentation.dailyUsage(for: $0)) })
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(0..<12, id: \.self) { index in
                    if let month = calendar.date(byAdding: .month, value: index, to: yearStart) {
                        let values = Dictionary(uniqueKeysWithValues: meters.compactMap { meter in
                            let daily = histories[meter.id] ?? [:]
                            return presentation.monthlyUsage(for: meter, month: month, now: now, daily: daily)
                                .map { (meter.id, $0) }
                        })
                        monthCell(index + 1, values: values, current: calendar.isDate(month, equalTo: now, toGranularity: .month))
                    }
                }
            }
            .padding(.bottom, 18)
        }
    }

    private func monthCell(_ number: Int, values: [String: Double], current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("\(number) 月")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(current ? Color.accentColor : .primary)
            QuotaColumns(meters: meters, values: values, height: 50)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            if current {
                RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.6))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(number) 月")
    }
}

struct QuotaTimeline: View {
    let day: Date
    let presentation: QuotaPresentation
    let meters: [Meter]

    private let hourHeight: CGFloat = 48
    private let axisWidth: CGFloat = 51
    private let laneSpacing: CGFloat = 8

    var body: some View {
        if let interval = presentation.calendar.dateInterval(of: .day, for: day) {
            let now = Date()
            let blocks = Dictionary(uniqueKeysWithValues: meters.map {
                ($0.id, presentation.timeBlocks(for: $0, in: interval, now: now))
            })
            VStack(spacing: 5) {
                laneHeaders(isToday: presentation.calendar.isDate(day, inSameDayAs: now))
                ScrollViewReader { scroll in
                    ScrollView {
                        timeline(interval: interval, blocks: blocks)
                            .padding(.bottom, 16)
                    }
                    .onChange(of: interval.start, initial: true) {
                        scroll.scrollTo(initialHour(in: interval, blocks: blocks), anchor: .top)
                    }
                }
            }
        }
    }

    private func laneHeaders(isToday: Bool) -> some View {
        HStack(alignment: .top, spacing: laneSpacing) {
            Color.clear.frame(width: axisWidth, height: 1)
            ForEach(meters) { meter in
                VStack(alignment: .leading, spacing: 3) {
                    Text(meter.shortPoolName).font(.caption.weight(.semibold)).foregroundStyle(meter.tint)
                    if isToday && meter.windows.last?.resetsAt == nil {
                        let remaining = max(0, 100 - meter.latest.used)
                        HStack(spacing: 7) {
                            horizontalBar(remaining, meter: meter, height: 12)
                            Text("剩余 \(quotaPercent(remaining))")
                                .font(.caption2.monospacedDigit()).fixedSize()
                        }
                        Text("周期时间待平台返回").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
            }
        }
    }

    private func timeline(interval: DateInterval, blocks: [String: [TimelineBlock]]) -> some View {
        let hourCount = Int((interval.duration / 3600).rounded(.up))
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<hourCount, id: \.self) { index in
                    let hour = interval.start.addingTimeInterval(Double(index) * 3600)
                    HStack(alignment: .top, spacing: laneSpacing) {
                        Text(clockTime(hour))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: axisWidth, alignment: .trailing)
                        Rectangle().fill(Color.primary.opacity(0.12))
                            .frame(height: 1).padding(.top, 6)
                    }
                    .frame(height: hourHeight, alignment: .top)
                    .id(hour)
                }
            }
            HStack(spacing: laneSpacing) {
                ForEach(meters) { meter in
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 7).fill(meter.tint.opacity(0.035))
                        ForEach(blocks[meter.id, default: []]) { block in
                            timelineBar(block, meter: meter)
                                .padding(.horizontal, 4)
                                .offset(y: points(block.visibleInterval.start.timeIntervalSince(interval.start)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.leading, axisWidth + laneSpacing)
            .padding(.top, 6)
        }
        .frame(height: points(interval.duration) + 6, alignment: .top)
    }

    private func timelineBar(_ block: TimelineBlock, meter: Meter) -> some View {
        let tint = meter.tint
        let height = max(2, points(block.visibleInterval.duration) - 3)
        let value = "\(block.remaining ? "剩余" : "已用") \(quotaPercent(block.percentage))"
        let range = "\(block.approximate ? "约 " : "")\(clockTime(block.interval.start)) – \(clockTime(block.interval.end))"
        return VStack(alignment: .leading, spacing: 5) {
            if height >= 49 {
                Text(range)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if height >= 25 {
                HStack(spacing: 7) {
                    horizontalBar(block.percentage, meter: meter, height: min(25, max(10, height * 0.18)))
                    Text(value)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint)
                        .fixedSize()
                }
            } else {
                horizontalBar(block.percentage, meter: meter, height: min(9, height))
            }
        }
        .padding(.horizontal, height >= 25 ? 8 : 2)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7).strokeBorder(tint.opacity(0.38))
        }
        .clipped()
        .help("\(range) · \(value)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.latest.pool) \(range)")
        .accessibilityValue(value)
    }

    private func horizontalBar(_ percentage: Double, meter: Meter, height: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(meter.tint.opacity(0.11))
                Capsule().strokeBorder(meter.tint.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                if percentage > 0 {
                    Capsule().fill(meter.gradient).frame(width: geometry.size.width * fillFraction(percentage))
                }
            }
        }
        .frame(height: height)
    }

    private func points(_ seconds: TimeInterval) -> CGFloat {
        CGFloat(seconds / 3600) * hourHeight
    }

    private func initialHour(in day: DateInterval, blocks: [String: [TimelineBlock]]) -> Date {
        let focus: Date
        if day.contains(Date()) {
            focus = Date().addingTimeInterval(-2 * 3600)
        } else {
            focus = blocks.values.flatMap { $0 }.map(\.visibleInterval.start).min() ?? day.start
        }
        let offset = max(0, (focus.timeIntervalSince(day.start) / 3600).rounded(.down))
        return day.start.addingTimeInterval(offset * 3600)
    }

    private func clockTime(_ date: Date) -> String {
        let clock = presentation.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", clock.hour ?? 0, clock.minute ?? 0)
    }
}
