import CryptoKit
import Foundation
import SQLite3

/// Each connection is owned by one executor. Normal history queries never materialize all bodies.
final class ClipboardHistoryStore {
    struct Stats {
        let count: Int
        let pinned: Int
        let bytes: Int
    }

    struct Attachment {
        let image: String?
        let rtf: String?
    }

    struct StorageError: Error {
        let code: Int32
    }

    private enum Value {
        case text(String), int(Int), real(Double), null

        init(_ text: String?) { self = text.map(Value.text) ?? .null }

        func bind(_ statement: OpaquePointer, _ index: Int32) -> Int32 {
            switch self {
            case .text(let text):
                return text.withCString {
                    guard let length = Int32(exactly: text.utf8.count) else { return SQLITE_TOOBIG }
                    return sqlite3_bind_text(statement, index, $0, length, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .int(let value): return sqlite3_bind_int64(statement, index, Int64(value))
            case .real(let value): return sqlite3_bind_double(statement, index, value)
            case .null: return sqlite3_bind_null(statement, index)
            }
        }
    }

    private let db: OpaquePointer
    private static let columns = "id,kind,image,rtf,color,saved,pinned,source,bundle,copies,bytes,digest,preview"
    private static let newest = "saved DESC, rowid DESC"

    init(url: URL, readOnly: Bool = false) throws {
        var connection: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(url.path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw StorageError(code: result)
        }
        do {
            try Self.configureReader(connection)
            if !readOnly { try Self.configureWriter(connection, url: url) }
        } catch {
            sqlite3_close(connection)
            throw error
        }
        db = connection
    }

    private static func configureReader(_ db: OpaquePointer) throws {
        try configureSQL(db, "PRAGMA cache_size=-1024")
        sqlite3_busy_timeout(db, 150)
        try Self.check(sqlite3_create_function_v2(db, "clip_contains", 2, SQLITE_UTF8, nil, { context, _, values in
            guard let values, let value = ClipboardHistoryStore.valueText(values[0]), let needle = ClipboardHistoryStore.valueText(values[1]) else {
                sqlite3_result_int(context, 0)
                return
            }
            sqlite3_result_int(context, value.localizedCaseInsensitiveContains(needle) ? 1 : 0)
        }, nil, nil, nil))
    }

    private static func configureWriter(_ db: OpaquePointer, url: URL) throws {
        // Set permissions before creating WAL/SHM files.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try configureSQL(db, "PRAGMA journal_mode=WAL")
        try configureSQL(db, "PRAGMA synchronous=FULL")
        try configureSQL(db, "PRAGMA secure_delete=ON")
        try configureSQL(db, """
            CREATE TABLE IF NOT EXISTS clips (
                id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, image TEXT, rtf TEXT, color TEXT,
                saved REAL NOT NULL, pinned INTEGER NOT NULL, source TEXT NOT NULL, bundle TEXT NOT NULL,
                copies INTEGER NOT NULL, bytes INTEGER NOT NULL, digest TEXT NOT NULL,
                preview TEXT NOT NULL, dedupe TEXT, body TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS clips_saved ON clips(saved DESC);
            CREATE INDEX IF NOT EXISTS clips_pinned_saved ON clips(pinned DESC, saved DESC);
            CREATE INDEX IF NOT EXISTS clips_dedupe ON clips(kind, dedupe, saved DESC);
            CREATE TABLE IF NOT EXISTS clipboard_meta (key TEXT PRIMARY KEY);
            """)
    }

    private static func configureSQL(_ db: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    deinit { sqlite3_close(db) }

    /// Import once, then remove the obsolete plaintext copy only after the transaction commits.
    /// If removal fails, the marker prevents a later launch from resurrecting deleted records.
    func migrateLegacy(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let migrated = try query("SELECT 1 FROM clipboard_meta WHERE key = 'legacy-json-v1'") { _ in true }
        if migrated.isEmpty {
            let items = try JSONDecoder().decode([ClipItem].self, from: Data(contentsOf: url, options: .mappedIfSafe))
            try transaction {
                for item in items.reversed() {
                    try write(item, dedupeKey: Self.dedupeKey(item), insertingOnly: true)
                }
                try execute("INSERT INTO clipboard_meta(key) VALUES ('legacy-json-v1')")
            }
        }
        try FileManager.default.removeItem(at: url)
    }

    func recent(keeping cached: [ClipItem] = []) throws -> [ClipItem] {
        let top = try page(query: "", filter: .all, pinnedFirst: false, limit: 5, offset: 0)
        return try top.map { summary in
            if let previous = cached.first(where: { $0.id == summary.id && $0.date == summary.date }) {
                var full = summary
                full.text = previous.text
                full.storedPreview = nil
                return full
            }
            guard let full = try item(id: summary.id) else { throw StorageError(code: SQLITE_NOTFOUND) }
            return full
        }
    }

    func item(id: UUID) throws -> ClipItem? {
        try query("SELECT \(Self.columns),body FROM clips WHERE id=?", [.text(id.uuidString)]) {
            try Self.item($0, full: true)
        }.first
    }

    func page(query needle: String, filter: ClipFilter, pinnedFirst: Bool, limit: Int, offset: Int) throws -> [ClipItem] {
        let kind: String
        switch filter {
        case .all: kind = "1"
        case .pinned: kind = "pinned=1"
        case .text: kind = "kind IN ('text','rich')"
        case .link: kind = "kind='link'"
        case .image: kind = "kind='image'"
        case .file: kind = "kind='file'"
        case .color: kind = "kind='color'"
        }
        let search = needle.isEmpty ? "" : " AND (clip_contains(preview,?1) OR clip_contains(body,?1) OR clip_contains(color,?1))"
        let bindings: [Value] = (needle.isEmpty ? [] : [.text(needle)]) + [.int(limit), .int(offset)]
        let order = (pinnedFirst ? "pinned DESC, " : "") + Self.newest
        return try query("SELECT \(Self.columns) FROM clips WHERE \(kind)\(search) ORDER BY \(order) LIMIT ? OFFSET ?", bindings) {
            try Self.item($0, full: false)
        }
    }

    func stats() throws -> Stats {
        try query("SELECT count(*), coalesce(sum(pinned),0), coalesce(sum(bytes),0) FROM clips") {
            Stats(count: Int(sqlite3_column_int64($0, 0)), pinned: Int(sqlite3_column_int64($0, 1)),
                  bytes: Int(sqlite3_column_int64($0, 2)))
        }[0]
    }

    /// Store every copy durably, even the five hot entries; eviction is atomic with insertion.
    func record(_ item: ClipItem, dedupe: Bool, limit: Int) throws -> (duplicate: Bool, removed: [Attachment]) {
        try transaction {
            let dedupeKey = Self.dedupeKey(item)
            if dedupe, let key = dedupeKey {
                let match = try query("SELECT id FROM clips WHERE kind=? AND dedupe=? ORDER BY \(Self.newest) LIMIT 1",
                                      [.text(item.kind.rawValue), .text(key)]) { Self.text($0, 0) }.first
                if let match {
                    try perform("UPDATE clips SET saved=?,copies=copies+1,source=?,bundle=? WHERE id=?",
                                [.real(item.date.timeIntervalSince1970), .text(item.source), .text(item.sourceBundle), .text(match)])
                    return (true, [])
                }
            }
            try write(item, dedupeKey: dedupeKey)
            return (false, try trimInsideTransaction(limit: limit))
        }
    }

    func trim(limit: Int) throws -> [Attachment] {
        try transaction { try trimInsideTransaction(limit: limit) }
    }

    func setPinned(id: UUID, pinned: Bool, limit: Int) throws -> [Attachment] {
        try transaction {
            try perform("UPDATE clips SET pinned=? WHERE id=?", [.int(pinned ? 1 : 0), .text(id.uuidString)])
            return pinned ? [] : try trimInsideTransaction(limit: limit)
        }
    }

    func update(_ item: ClipItem) throws { try write(item, dedupeKey: Self.dedupeKey(item), existingOnly: true) }

    func delete(id: UUID) throws -> [Attachment] { try remove("id=?", [.text(id.uuidString)]) }
    func clear(keepPinned: Bool) throws -> [Attachment] {
        let removed = try remove(keepPinned ? "pinned=0" : "1")
        // Best effort: compact the journal after an explicit clear. Do not invalidate the committed result.
        try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return removed
    }

    private func trimInsideTransaction(limit: Int) throws -> [Attachment] {
        let count = try query("SELECT count(*) FROM clips") { Int(sqlite3_column_int64($0, 0)) }[0]
        let overflow = max(0, count - max(0, limit))
        guard overflow > 0 else { return [] }
        return try deleteMatching("rowid IN (SELECT rowid FROM clips WHERE pinned=0 ORDER BY saved ASC,rowid ASC LIMIT ?)", [.int(overflow)])
    }

    private func remove(_ predicate: String, _ bindings: [Value] = []) throws -> [Attachment] {
        try transaction { try deleteMatching(predicate, bindings) }
    }

    private func deleteMatching(_ predicate: String, _ bindings: [Value]) throws -> [Attachment] {
        try query("DELETE FROM clips WHERE \(predicate) RETURNING image,rtf", bindings) {
            Attachment(image: Self.optionalText($0, 0), rtf: Self.optionalText($0, 1))
        }
    }

    private func write(_ item: ClipItem, dedupeKey: String?, insertingOnly: Bool = false, existingOnly: Bool = false) throws {
        let cols = "kind,image,rtf,color,saved,pinned,source,bundle,copies,bytes,digest,preview,dedupe,body"
        let values: [Value] = [
            .text(item.kind.rawValue), Value(item.imageFile), Value(item.rtfFile), Value(item.colorHex),
            .real(item.date.timeIntervalSince1970), .int(item.pinned ? 1 : 0), .text(item.source), .text(item.sourceBundle),
            .int(item.copies), .int(item.byteCount), .text(item.digest), .text(item.preview), Value(dedupeKey),
            .text(item.text), .text(item.id.uuidString)
        ]
        if existingOnly {
            let assignments = cols.split(separator: ",").map { "\($0)=?" }.joined(separator: ",")
            try perform("UPDATE clips SET \(assignments) WHERE id=?", values)
        } else {
            let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
            let conflict = insertingOnly ? " ON CONFLICT(id) DO NOTHING" : ""
            try perform("INSERT INTO clips (\(cols),id) VALUES (\(placeholders))\(conflict)", values)
        }
    }

    private static func dedupeKey(_ item: ClipItem) -> String? {
        switch item.kind {
        case .image: return item.digest.isEmpty ? nil : item.digest
        case .color: return item.colorHex
        default:
            let bytes = Data(item.text.precomposedStringWithCanonicalMapping.utf8)
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func item(_ s: OpaquePointer, full: Bool) throws -> ClipItem {
        guard let id = UUID(uuidString: text(s, 0)), let kind = ClipKind(rawValue: text(s, 1)) else {
            throw StorageError(code: SQLITE_CORRUPT)
        }
        var item = ClipItem(id: id, kind: kind, text: full ? text(s, 13) : "",
                            imageFile: optionalText(s, 2), rtfFile: optionalText(s, 3), colorHex: optionalText(s, 4),
                            date: Date(timeIntervalSince1970: sqlite3_column_double(s, 5)), pinned: sqlite3_column_int(s, 6) != 0,
                            source: text(s, 7), sourceBundle: text(s, 8), copies: Int(sqlite3_column_int64(s, 9)),
                            byteCount: Int(sqlite3_column_int64(s, 10)), digest: text(s, 11))
        if !full { item.storedPreview = text(s, 12) }
        return item
    }

    private static func readString(_ pointer: UnsafePointer<UInt8>, _ size: Int32) -> String {
        String(decoding: UnsafeBufferPointer(start: pointer, count: Int(size)), as: UTF8.self)
    }

    private static func optionalText(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let value = sqlite3_column_text(s, i) else { return nil }
        return readString(value, sqlite3_column_bytes(s, i))
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String { optionalText(s, i) ?? "" }

    private static func valueText(_ value: OpaquePointer?) -> String? {
        guard let bytes = sqlite3_value_text(value) else { return nil }
        return readString(bytes, sqlite3_value_bytes(value))
    }

    private static func check(_ rc: Int32, expected: Int32 = SQLITE_OK) throws {
        guard rc == expected else { throw StorageError(code: rc) }
    }

    private func execute(_ sql: String) throws { try Self.check(sqlite3_exec(db, sql, nil, nil, nil)) }

    private func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try block()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func perform(_ sql: String, _ values: [Value]) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        var handle: OpaquePointer?
        try Self.check(sqlite3_prepare_v2(db, sql, -1, &handle, nil))
        guard let statement = handle else { throw StorageError(code: SQLITE_MISUSE) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { try Self.check(value.bind(statement, Int32(index + 1))) }
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return rows }
            try Self.check(rc, expected: SQLITE_ROW)
            rows.append(try row(statement))
        }
    }
}
