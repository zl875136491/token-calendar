import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var ledger = Ledger()
    @Published private(set) var issues: [Provider: String] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var storageIssue: String?
    private var polling: Task<Void, Never>?
    private let store = QuotaStore(folder: supportDirectory)

    init() {
        do {
            ledger = try store.load()
        } catch {
            storageIssue = "用量记录无法读取，采集已暂停。"
        }
    }

    func start() {
        guard polling == nil else { return }
        polling = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func refresh() async {
        guard !refreshing, storageIssue == nil else { return }
        refreshing = true
        defer { refreshing = false }
        let reports = await collectReports()
        var updated = ledger
        var changed = Set<String>()
        for (provider, report) in reports {
            issues[provider] = report.issue
            changed.formUnion(updated.record(report.readings))
        }
        do {
            try store.save(updated, replacing: ledger, changed: changed)
            ledger = updated
        } catch {
            storageIssue = "无法保存用量记录，请检查本机存储空间和目录权限。"
        }
    }
}

func collectReports() async -> [Provider: SourceReport] {
    await withTaskGroup(of: (Provider, SourceReport).self) { group in
        for provider in Provider.allCases {
            group.addTask { (provider, await provider.collect()) }
        }
        var result: [Provider: SourceReport] = [:]
        for await (provider, report) in group { result[provider] = report }
        return result
    }
}

struct TokenCalendarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Token Calendar", id: "calendar") {
            Dashboard(model: model)
                .frame(minWidth: 920, minHeight: 650)
                .preferredColorScheme(.dark)
                .task { model.start() }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新额度") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

struct Dashboard: View {
    @ObservedObject var model: AppModel
    @State private var period: Period = .week
    @State private var weekMonth = Date()
    @State private var hourDay = Date()
    @State private var year = Date()
    @State private var showDetails = false

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }()

    private var presentation: QuotaPresentation {
        QuotaPresentation(meters: Array(model.ledger.meters.values), calendar: calendar)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle()
                .fill(CalendarAppearance.border)
                .frame(height: 1)
            if let issue = model.storageIssue {
                Text(issue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.orange.opacity(0.14))
            }
            VStack(alignment: .leading, spacing: 11) {
                navigation
                legend
                periodView
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, CalendarAppearance.windowInset)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
        }
        .background(CalendarAppearance.background)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(CalendarAppearance.surface, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            Text("额度日历").font(.title2.bold())
            Spacer()
            Picker("额度周期", selection: $period) {
                ForEach(Period.allCases) { option in
                    Text(option == .fiveHours ? option.rawValue : "\(option.rawValue)额度").tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)
            Spacer()
            Button { Task { await model.refresh() } } label: {
                Label(model.refreshing ? "采集中" : "刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.refreshing || model.storageIssue != nil)
            Button { showDetails.toggle() } label: {
                Label("明细", systemImage: "list.bullet.rectangle")
            }
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                CurrentDetails(model: model, presentation: presentation)
            }
        }
        .padding(.horizontal, CalendarAppearance.windowInset)
        .padding(.vertical, 12)
    }

    private var navigation: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(homeLabel) { setDate(Date()) }
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("上一\(dateUnit)")
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("下一\(dateUnit)")
        }
    }

    @ViewBuilder private var legend: some View {
        let meters = presentation.pools(in: period)
        if !meters.isEmpty {
            HStack(spacing: 8) {
                ForEach(meters) { meter in
                    HStack(spacing: 6) {
                        Circle().fill(meter.gradient).frame(width: 8, height: 8)
                        Text(meter.shortPoolName).fontWeight(.semibold)
                        if period == .week, meter.windows.last?.resetsAt == nil {
                            Text("剩余 \(quotaPercent(max(0, 100 - meter.latest.used)))")
                                .foregroundStyle(.secondary)
                                .help("平台尚未给出重置时间")
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(CalendarAppearance.surface, in: RoundedRectangle(cornerRadius: 7))
                    .help("\(meter.latest.provider.rawValue) · \(meter.latest.pool)")
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var periodView: some View {
        let meters = presentation.pools(in: period)
        if meters.isEmpty {
            ContentUnavailableView("暂无此周期额度", systemImage: "calendar")
        } else {
            switch period {
            case .fiveHours:
                QuotaTimeline(day: hourDay, presentation: presentation, meters: meters)
            case .week:
                WeekCalendar(month: weekMonth, presentation: presentation, meters: meters)
            case .month:
                MonthMatrix(year: year, presentation: presentation, meters: meters)
            }
        }
    }

    private var title: String {
        let components = calendar.dateComponents([.year, .month, .day], from: selectedDate)
        let year = components.year ?? 0
        let month = components.month ?? 0
        switch period {
        case .fiveHours: return "\(year) 年 \(month) 月 \(components.day ?? 0) 日"
        case .week: return "\(year) 年 \(month) 月"
        case .month: return "\(year) 年"
        }
    }

    private var subtitle: String {
        switch period {
        case .fiveHours: return "当前周期显示剩余 · 已结束的周期显示当天记录的消耗"
        case .week: return "历史日期显示当天记录的消耗 · 从今天起将各池剩余额度均分到重置前"
        case .month: return "本月显示当前账期已用额度 · 历史月份汇总每天记录的消耗"
        }
    }

    private var selectedDate: Date {
        switch period {
        case .fiveHours: return hourDay
        case .week: return weekMonth
        case .month: return year
        }
    }

    private var homeLabel: String {
        switch period {
        case .fiveHours: return "今天"
        case .week: return "本月"
        case .month: return "今年"
        }
    }

    private var dateUnit: String {
        switch period {
        case .fiveHours: return "天"
        case .week: return "月"
        case .month: return "年"
        }
    }

    private func setDate(_ date: Date) {
        switch period {
        case .fiveHours: hourDay = date
        case .week: weekMonth = date
        case .month: year = date
        }
    }

    private func move(_ offset: Int) {
        let unit: Calendar.Component
        switch period {
        case .fiveHours: unit = .day
        case .week: unit = .month
        case .month: unit = .year
        }
        let start = calendar.dateInterval(of: unit, for: selectedDate)?.start ?? selectedDate
        if let shifted = calendar.date(byAdding: unit, value: offset, to: start) { setDate(shifted) }
    }
}

private struct CurrentDetails: View {
    @ObservedObject var model: AppModel
    let presentation: QuotaPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前额度明细").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                ForEach(Provider.allCases) { provider in providerCard(provider) }
            }
        }
        .padding(16)
        .frame(width: 864)
        .fixedSize(horizontal: false, vertical: true)
        .background(CalendarAppearance.background)
    }

    private func providerCard(_ provider: Provider) -> some View {
        let meters = Period.allCases.flatMap { presentation.pools(for: provider, period: $0) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(provider.rawValue, systemImage: "circle.fill")
                    .font(.headline).foregroundStyle(provider.color)
                Spacer()
                if let latest = meters.map(\.latest.sampledAt).max() {
                    Text(latest, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let issue = model.issues[provider] {
                Text(issue).font(.caption).foregroundStyle(.orange)
            } else if meters.isEmpty {
                Text("等待首次采样").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(meters) { meter in
                let reading = meter.latest
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(reading.pool) · \(reading.period.rawValue)").font(.subheadline)
                        Spacer()
                        Text("已用 \(quotaPercent(reading.used))").font(.caption.monospacedDigit())
                    }
                    ProgressView(value: min(reading.used, 100), total: 100)
                        .tint(meter.tint)
                        .accessibilityLabel("已用额度")
                    HStack {
                        if let reset = reading.resetsAt {
                            Text("\(reading.approximate ? "约 " : "")\(reset.formatted(.dateTime.month().day().hour().minute())) 重置")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let increase = meter.windows.last?.increase, increase > 0 {
                            Text("新增 \(increase.formatted(.number.precision(.fractionLength(0...2)))) 个百分点")
                                .foregroundStyle(meter.tint)
                        }
                    }
                    .font(.caption2.monospacedDigit())
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CalendarAppearance.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(CalendarAppearance.border)
        }
    }
}
