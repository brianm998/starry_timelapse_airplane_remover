import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import StarCoreSQLite
#endif
import logging

// SQLITE_TRANSIENT is not automatically bridged in Swift
private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)

/// Actor that persists neighbor homography results in a per-sequence SQLite database.
///
/// Replaces per-frame JSON files under `aligned/{frameIndex}/neighbor_{star,earth}_homography.json`.
/// WAL mode allows concurrent reads while the single actor serialises all writes.
public actor HomographyDatabase {

    public enum HomographyType: String, Sendable {
        case star  = "star"
        case earth = "earth"
    }

    private var db: OpaquePointer?
    public let dbPath: String

    public init(tempOutputPath: String) {
        self.dbPath = "\(tempOutputPath)/homography.db"
    }

    // MARK: - Public API

    public func write(
        frameIndex: Int,
        type: HomographyType,
        results: HomographyResultsCodable
    ) throws {
        try ensureOpen()
        let data = try JSONEncoder().encode(results)
        let sql = "INSERT OR REPLACE INTO homographies (frame_index, type, data) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw "HomographyDatabase: prepare failed for write"
        }
        sqlite3_bind_int(stmt, 1, Int32(frameIndex))
        sqlite3_bind_text(stmt, 2, type.rawValue, -1, SQLITE_TRANSIENT_PTR)
        data.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(data.count), SQLITE_TRANSIENT_PTR)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw "HomographyDatabase: step failed for write frame \(frameIndex)/\(type.rawValue)"
        }
    }

    public func read(
        frameIndex: Int,
        type: HomographyType
    ) throws -> HomographyResultsCodable? {
        try ensureOpen()
        let sql = "SELECT data FROM homographies WHERE frame_index = ? AND type = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw "HomographyDatabase: prepare failed for read"
        }
        sqlite3_bind_int(stmt, 1, Int32(frameIndex))
        sqlite3_bind_text(stmt, 2, type.rawValue, -1, SQLITE_TRANSIENT_PTR)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        let data = Data(bytes: blob, count: count)
        return try JSONDecoder().decode(HomographyResultsCodable.self, from: data)
    }

    /// Which frames already have a stored homography of `type`.
    ///
    /// For surveying how far a previous run got without reading any of it: one query for
    /// the whole sequence rather than a `read` per frame, and no blob decode — the frame
    /// numbers are the answer, and `HomographyResultsCodable` is the expensive part.
    ///
    /// Answers `[]` for a sequence that has never stored one, rather than creating the
    /// database to find that out.  `ensureOpen` opens for writing and creates the table,
    /// which is right for every other caller here and wrong for this one: this is asked
    /// when a sequence is *opened*, and opening a sequence should leave nothing behind.
    public func storedFrameIndices(type: HomographyType) throws -> Set<Int> {
        guard db != nil || FileManager.default.fileExists(atPath: dbPath) else { return [] }
        try ensureOpen()
        let sql = "SELECT frame_index FROM homographies WHERE type = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw "HomographyDatabase: prepare failed for storedFrameIndices"
        }
        sqlite3_bind_text(stmt, 1, type.rawValue, -1, SQLITE_TRANSIENT_PTR)
        var indices: Set<Int> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            indices.insert(Int(sqlite3_column_int(stmt, 0)))
        }
        return indices
    }

    public func delete(frameIndex: Int, type: HomographyType) throws {
        try ensureOpen()
        let sql = "DELETE FROM homographies WHERE frame_index = ? AND type = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw "HomographyDatabase: prepare failed for delete"
        }
        sqlite3_bind_int(stmt, 1, Int32(frameIndex))
        sqlite3_bind_text(stmt, 2, type.rawValue, -1, SQLITE_TRANSIENT_PTR)
        _ = sqlite3_step(stmt)
    }

    /// Deletes all homography rows for a frame (both star and earth).
    public func deleteAll(frameIndex: Int) throws {
        try ensureOpen()
        let sql = "DELETE FROM homographies WHERE frame_index = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw "HomographyDatabase: prepare failed for deleteAll"
        }
        sqlite3_bind_int(stmt, 1, Int32(frameIndex))
        _ = sqlite3_step(stmt)
    }

    // MARK: - Private helpers

    private func ensureOpen() throws {
        guard db == nil else { return }
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw "HomographyDatabase: cannot open \(dbPath): \(msg)"
        }
        try runSQL("PRAGMA journal_mode=WAL")
        try runSQL("PRAGMA synchronous=NORMAL")
        try runSQL("""
            CREATE TABLE IF NOT EXISTS homographies (
                frame_index INTEGER NOT NULL,
                type        TEXT    NOT NULL,
                data        BLOB    NOT NULL,
                PRIMARY KEY (frame_index, type)
            )
        """)
    }

    private func runSQL(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let msg = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw "HomographyDatabase SQL error: \(msg)"
        }
    }
}
