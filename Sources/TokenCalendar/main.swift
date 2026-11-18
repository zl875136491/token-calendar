import Darwin
import Foundation
import SwiftUI

signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.dropFirst() == ["--check-sources"] {
    Task.detached {
        let reports = await collectReports()
        var failures = 0
        for provider in Provider.allCases {
            let report = reports[provider] ?? SourceReport([])
            print(provider.rawValue)
            for reading in report.readings.sorted(by: { $0.id < $1.id }) {
                let end = reading.resetsAt?.ISO8601Format() ?? "—"
                print("  \(reading.pool) · \(reading.period.rawValue): \(reading.used)%  \(end)")
            }
            if let issue = report.issue { print("  \(issue)") }
            if report.readings.isEmpty || report.issue != nil { failures += 1 }
        }
        exit(failures == 0 ? 0 : 1)
    }
    dispatchMain()
} else {
    TokenCalendarApp.main()
}
