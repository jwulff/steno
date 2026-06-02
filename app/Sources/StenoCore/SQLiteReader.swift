import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal read-only SQLite reader over the daemon's `steno.sqlite`.
///
/// Opens the database `SQLITE_OPEN_READONLY`; the daemon is the sole writer and
/// keeps WAL active, so the app only ever reads regenerable view data
/// (topics, segments, summaries). All queries exclude `duplicate_of IS NOT
/// NULL` rows, matching the TUI's default dedup filter.
public final class SQLiteReader: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "steno.sqlite.reader")

    public init?(path: String = StenoPaths.databaseURL.path) {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
        self.db = handle
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Queries

    public func topics(sessionId: String) -> [Topic] {
        let sql = """
        SELECT id, title, summary, segmentRangeStart, segmentRangeEnd, createdAt
        FROM topics WHERE sessionId = ? ORDER BY segmentRangeStart ASC
        """
        return query(sql, bind: [sessionId]) { stmt in
            Topic(
                id: text(stmt, 0),
                title: text(stmt, 1),
                summary: text(stmt, 2),
                rangeStart: Int(sqlite3_column_int64(stmt, 3)),
                rangeEnd: Int(sqlite3_column_int64(stmt, 4)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            )
        }
    }

    public func segments(sessionId: String, rangeStart: Int, rangeEnd: Int) -> [TranscriptEntry] {
        let sql = """
        SELECT id, text, startedAt, sequenceNumber, source, speaker_id, heal_marker
        FROM segments
        WHERE sessionId = ? AND sequenceNumber >= ? AND sequenceNumber <= ?
          AND duplicate_of IS NULL
        ORDER BY sequenceNumber ASC
        """
        return query(sql, bind: [sessionId, rangeStart, rangeEnd]) { stmt in
            TranscriptEntry(
                id: text(stmt, 0),
                kind: .segment,
                source: AudioSource(rawValue: text(stmt, 4)),
                text: text(stmt, 1),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                sequenceNumber: Int(sqlite3_column_int64(stmt, 3)),
                speakerId: optionalText(stmt, 5),
                healMarker: optionalText(stmt, 6)
            )
        }
    }

    public func latestSummary(sessionId: String) -> Summary? {
        let sql = """
        SELECT content, summaryType, createdAt FROM summaries
        WHERE sessionId = ? ORDER BY createdAt DESC, rowid DESC LIMIT 1
        """
        return query(sql, bind: [sessionId]) { stmt in
            Summary(
                content: text(stmt, 0),
                summaryType: text(stmt, 1),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            )
        }.first
    }

    // MARK: - Engine

    private func query<T>(
        _ sql: String,
        bind params: [Any],
        map: (OpaquePointer) -> T
    ) -> [T] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            for (i, param) in params.enumerated() {
                let idx = Int32(i + 1)
                switch param {
                case let s as String:
                    sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
                case let n as Int:
                    sqlite3_bind_int64(stmt, idx, Int64(n))
                default:
                    break
                }
            }

            var rows: [T] = []
            while sqlite3_step(stmt) == SQLITE_ROW, let stmt {
                rows.append(map(stmt))
            }
            return rows
        }
    }
}

// MARK: - Column helpers

private func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
    guard let c = sqlite3_column_text(stmt, col) else { return "" }
    return String(cString: c)
}

private func optionalText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
    guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
          let c = sqlite3_column_text(stmt, col) else { return nil }
    return String(cString: c)
}
