import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local state: SQLite (WAL) with JSON documents. Every state change is written immediately,
/// so a crash or quit never loses queued work or finished runs.
public final class Store {
    public let dir: URL
    private var db: OpaquePointer?
    private let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public init(dir: URL) throws {
        self.dir = dir
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("runs"), withIntermediateDirectories: true)
        guard sqlite3_open(dir.appendingPathComponent("state.sqlite").path, &db) == SQLITE_OK else {
            throw NSError(domain: "Store", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open database"])
        }
        try exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS tracked(id TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, mr_id TEXT NOT NULL, started REAL NOT NULL, json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS runs_mr ON runs(mr_id);
        CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT, mr_id TEXT, at REAL, sha TEXT, action TEXT, detail TEXT);
        """)
    }

    deinit { sqlite3_close(db) }

    public static var defaultDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReviewBar")
    }

    public func runDir(_ runID: String) -> URL { dir.appendingPathComponent("runs/\(runID)") }

    // MARK: tracked

    public func loadTracked() -> [Tracked] {
        query("SELECT json FROM tracked", []) { try? dec.decode(Tracked.self, from: Data(text($0, 0).utf8)) }.compactMap { $0 }
    }
    public func save(_ t: Tracked) {
        guard let data = try? enc.encode(t) else { return }
        run("INSERT OR REPLACE INTO tracked(id, json) VALUES(?, ?)", [t.id, String(decoding: data, as: UTF8.self)])
    }
    public func deleteTracked(_ id: String) { run("DELETE FROM tracked WHERE id = ?", [id]) }

    // MARK: runs

    public func save(_ r: ReviewRun) {
        guard let data = try? enc.encode(r) else { return }
        run("INSERT OR REPLACE INTO runs(id, mr_id, started, json) VALUES(?, ?, ?, ?)",
            [r.id, r.mrID, r.startedAt.timeIntervalSince1970, String(decoding: data, as: UTF8.self)])
    }
    public func run(id: String) -> ReviewRun? {
        query("SELECT json FROM runs WHERE id = ?", [id]) { try? dec.decode(ReviewRun.self, from: Data(text($0, 0).utf8)) }.first ?? nil
    }
    public func runs(mrID: String) -> [ReviewRun] {
        query("SELECT json FROM runs WHERE mr_id = ? ORDER BY started DESC", [mrID]) {
            try? dec.decode(ReviewRun.self, from: Data(text($0, 0).utf8))
        }.compactMap { $0 }
    }
    public func runs(since: Date) -> [ReviewRun] {
        query("SELECT json FROM runs WHERE started >= ?", [since.timeIntervalSince1970]) {
            try? dec.decode(ReviewRun.self, from: Data(text($0, 0).utf8))
        }.compactMap { $0 }
    }
    public func runningRuns() -> [ReviewRun] {
        runs(since: .distantPast).filter { $0.status == .running }
    }

    // MARK: audit (FR-16)

    public func audit(mrID: String, sha: String, action: String, detail: String = "") {
        run("INSERT INTO audit(mr_id, at, sha, action, detail) VALUES(?, ?, ?, ?, ?)",
            [mrID, Date().timeIntervalSince1970, sha, action, detail])
    }
    public func auditLog(mrID: String? = nil) -> [AuditEntry] {
        let sql = "SELECT id, mr_id, at, sha, action, detail FROM audit" + (mrID == nil ? "" : " WHERE mr_id = ?") + " ORDER BY id DESC"
        return query(sql, mrID.map { [$0] } ?? []) {
            AuditEntry(id: sqlite3_column_int64($0, 0), mrID: text($0, 1),
                       at: Date(timeIntervalSince1970: sqlite3_column_double($0, 2)),
                       sha: text($0, 3), action: text($0, 4), detail: text($0, 5))
        }
    }

    // MARK: sqlite plumbing

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "Store", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func prepare(_ sql: String, _ args: [Any]) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let s as String: sqlite3_bind_text(st, idx, s, -1, SQLITE_TRANSIENT)
            case let d as Double: sqlite3_bind_double(st, idx, d)
            case let n as Int: sqlite3_bind_int64(st, idx, Int64(n))
            default: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }

    private func run(_ sql: String, _ args: [Any]) {
        guard let st = prepare(sql, args) else { return }
        sqlite3_step(st)
        sqlite3_finalize(st)
    }

    private func query<T>(_ sql: String, _ args: [Any], _ row: (OpaquePointer) -> T) -> [T] {
        guard let st = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(row(st)) }
        return out
    }

    private func text(_ st: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(st, col).map { String(cString: $0) } ?? ""
    }
}
