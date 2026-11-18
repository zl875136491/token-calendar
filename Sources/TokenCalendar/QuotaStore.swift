import Foundation
import SQLite3

struct QuotaStore {
    let folder: URL
    private var file: URL { folder.appending(path: "observations.sqlite3") }
    private var legacy: URL { folder.appending(path: "observations.json") }

    func load() throws -> Ledger {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = try QuotaDatabase(url: file)
        var loaded = Ledger()
        try database.transaction {
            var version: Int32 = 0
            try database.rows("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
            switch version {
            case 0:
                try database.execute(Self.schema)
                let imported: Ledger
                do {
                    imported = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: legacy))
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    imported = Ledger()
                }
                for meter in imported.meters.values { try write(meter, to: database, startingAt: 0) }
                try database.execute("PRAGMA user_version = 1")
            case 1:
                break
            default:
                throw QuotaStoreError("额度数据库版本不受支持")
            }
            loaded = try read(database)
        }
        return loaded
    }

    private func read(_ database: QuotaDatabase) throws -> Ledger {
        var days: [String: [String: Double]] = [:]
        try database.rows("SELECT window_id, day, used FROM daily_usage") { row in
            days[columnText(row, 0), default: [:]][columnText(row, 1)] = sqlite3_column_double(row, 2)
        }
        var windows: [String: [ObservedWindow]] = [:]
        try database.rows("""
            SELECT id, meter_id, tracked_from, starts_at, resets_at, approximate, highest_observed, last_observed_used
            FROM quota_window ORDER BY meter_id, position
            """) { row in
            let id = columnText(row, 0)
            guard let uuid = UUID(uuidString: id), let tracked = columnDate(row, 2) else {
                throw QuotaStoreError("额度周期记录无效")
            }
            windows[columnText(row, 1), default: []].append(ObservedWindow(
                id: uuid, trackedFrom: tracked, startsAt: columnDate(row, 3), resetsAt: columnDate(row, 4),
                approximate: sqlite3_column_int(row, 5) != 0, highestObserved: sqlite3_column_double(row, 6),
                lastObservedUsed: columnNumber(row, 7), byDay: days[id] ?? [:]
            ))
        }
        var ledger = Ledger()
        try database.rows("""
            SELECT id, provider, account, pool, period, used, sampled_at, starts_at, resets_at, approximate
            FROM meter
            """) { row in
            let id = columnText(row, 0)
            guard let provider = Provider(rawValue: columnText(row, 1)),
                  let period = Period(rawValue: columnText(row, 4)),
                  let sampled = columnDate(row, 6),
                  let storedWindows = windows[id], !storedWindows.isEmpty else {
                throw QuotaStoreError("额度池记录无效")
            }
            let reading = Reading(
                provider: provider, account: columnText(row, 2), pool: columnText(row, 3), period: period,
                used: sqlite3_column_double(row, 5), sampledAt: sampled, startsAt: columnDate(row, 7),
                resetsAt: columnDate(row, 8), approximate: sqlite3_column_int(row, 9) != 0
            )
            guard id == reading.id else { throw QuotaStoreError("额度池标识无效") }
            ledger.meters[id] = Meter(latest: reading, windows: storedWindows)
        }
        return ledger
    }

    func save(_ ledger: Ledger, replacing previous: Ledger, changed: Set<String>) throws {
        guard !changed.isEmpty else { return }
        let database = try QuotaDatabase(url: file)
        try database.transaction {
            for id in changed {
                guard let meter = ledger.meters[id] else { continue }
                let previousCount = previous.meters[id]?.windows.count ?? 0
                try write(meter, to: database, startingAt: max(0, previousCount - 1))
            }
        }
    }

    private func write(_ meter: Meter, to database: QuotaDatabase, startingAt start: Int) throws {
        let reading = meter.latest
        try database.change("""
            INSERT INTO meter (id, provider, account, pool, period, used, sampled_at, starts_at, resets_at, approximate)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET used = excluded.used, sampled_at = excluded.sampled_at,
                starts_at = excluded.starts_at, resets_at = excluded.resets_at, approximate = excluded.approximate
            """, [
                .text(meter.id), .text(reading.provider.rawValue), .text(reading.account), .text(reading.pool),
                .text(reading.period.rawValue), .number(reading.used), .date(reading.sampledAt),
                .date(reading.startsAt), .date(reading.resetsAt), .integer(reading.approximate ? 1 : 0)
            ])
        for (index, window) in meter.windows.enumerated().dropFirst(start) {
            let id = window.id.uuidString
            try database.change("""
                INSERT INTO quota_window (id, meter_id, position, tracked_from, starts_at, resets_at,
                    approximate, highest_observed, last_observed_used)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET starts_at = excluded.starts_at, resets_at = excluded.resets_at,
                    approximate = excluded.approximate, highest_observed = excluded.highest_observed,
                    last_observed_used = excluded.last_observed_used
                """, [
                    .text(id), .text(meter.id), .integer(Int64(index)), .date(window.trackedFrom),
                    .date(window.startsAt), .date(window.resetsAt), .integer(window.approximate ? 1 : 0),
                    .number(window.highestObserved), window.lastObservedUsed.map(SQLValue.number) ?? .null
                ])
            for (day, used) in window.byDay {
                try database.change("""
                    INSERT INTO daily_usage (window_id, day, used) VALUES (?, ?, ?)
                    ON CONFLICT(window_id, day) DO UPDATE SET used = excluded.used
                    """, [.text(id), .text(day), .number(used)])
            }
        }
    }

    private static let schema = """
        CREATE TABLE meter (
            id TEXT PRIMARY KEY NOT NULL, provider TEXT NOT NULL, account TEXT NOT NULL, pool TEXT NOT NULL,
            period TEXT NOT NULL, used REAL NOT NULL, sampled_at REAL NOT NULL, starts_at REAL,
            resets_at REAL, approximate INTEGER NOT NULL
        );
        CREATE TABLE quota_window (
            id TEXT PRIMARY KEY NOT NULL, meter_id TEXT NOT NULL REFERENCES meter(id), position INTEGER NOT NULL,
            tracked_from REAL NOT NULL, starts_at REAL, resets_at REAL, approximate INTEGER NOT NULL,
            highest_observed REAL NOT NULL, last_observed_used REAL, UNIQUE (meter_id, position)
        );
        CREATE TABLE daily_usage (
            window_id TEXT NOT NULL REFERENCES quota_window(id), day TEXT NOT NULL, used REAL NOT NULL,
            PRIMARY KEY (window_id, day)
        );
        """
}

private struct QuotaStoreError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private enum SQLValue {
    case text(String), number(Double), integer(Int64), null

    static func date(_ value: Date?) -> SQLValue {
        value.map { .number($0.timeIntervalSince1970) } ?? .null
    }
}

private final class QuotaDatabase {
    private let db: OpaquePointer

    init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw QuotaStoreError("无法打开本机额度数据库")
        }
        db = handle
        sqlite3_busy_timeout(db, 1_500)
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(db) }

    func transaction(_ changes: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try changes()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func rows(_ sql: String, visit: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try visit(statement)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw error() }
    }

    func change(_ sql: String, _ values: [SQLValue]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let column = Int32(index + 1)
            let status: Int32
            switch value {
            case let .text(text): status = sqlite3_bind_text(statement, column, text, -1, transient)
            case let .number(number): status = sqlite3_bind_double(statement, column, number)
            case let .integer(number): status = sqlite3_bind_int64(statement, column, number)
            case .null: status = sqlite3_bind_null(statement, column)
            }
            guard status == SQLITE_OK else { throw error() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }

    private func error() -> QuotaStoreError {
        QuotaStoreError(String(cString: sqlite3_errmsg(db)))
    }
}

private func columnText(_ row: OpaquePointer, _ index: Int32) -> String {
    sqlite3_column_text(row, index).map { String(cString: $0) } ?? ""
}

private func columnNumber(_ row: OpaquePointer, _ index: Int32) -> Double? {
    sqlite3_column_type(row, index) == SQLITE_NULL ? nil : sqlite3_column_double(row, index)
}

private func columnDate(_ row: OpaquePointer, _ index: Int32) -> Date? {
    columnNumber(row, index).map(Date.init(timeIntervalSince1970:))
}
