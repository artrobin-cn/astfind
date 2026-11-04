import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String, code: Int32)
    case prepare(String, sql: String, message: String)
    case step(String, sql: String, message: String)
    case exec(String, sql: String, message: String)
    public var description: String {
        switch self {
        case .open(let p, let c): return "sqlite open failed: \(p) (code \(c))"
        case .prepare(let m, let sql, let msg): return "sqlite prepare \(m) [\(sql)] \(msg)"
        case .step(let m, let sql, let msg): return "sqlite step \(m) [\(sql)] \(msg)"
        case .exec(let m, let sql, let msg): return "sqlite exec \(m) [\(sql)] \(msg)"
        }
    }
}

public enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public final class Statement {
    fileprivate var handle: OpaquePointer?
    private let sql: String
    fileprivate init(handle: OpaquePointer?, sql: String) {
        self.handle = handle; self.sql = sql
    }
    deinit { sqlite3_finalize(handle) }

    public func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(handle, i)
            case .int(let v): code = sqlite3_bind_int64(handle, i, v)
            case .double(let v): code = sqlite3_bind_double(handle, i, v)
            case .text(let v): code = sqlite3_bind_text(handle, i, v, -1, SQLITE_TRANSIENT)
            case .blob(let v): code = v.withUnsafeBytes { sqlite3_bind_blob(handle, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
            guard code == SQLITE_OK else { throw SQLiteError.prepare("bind \(index)", sql: sql, message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle)))) }
        }
    }

    @discardableResult
    public func step() throws -> Bool {
        let code = sqlite3_step(handle)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        throw SQLiteError.step("code \(code)", sql: sql, message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
    }

    public func columnInt(_ index: Int32) -> Int64 { sqlite3_column_int64(handle, index) }
    public func columnDouble(_ index: Int32) -> Double { sqlite3_column_double(handle, index) }
    public func columnText(_ index: Int32) -> String { sqlite3_column_text(handle, index).map { String(cString: $0) } ?? "" }
    public func columnIsNull(_ index: Int32) -> Bool { sqlite3_column_type(handle, index) == SQLITE_NULL }
    /// BLOB 列（向量等二进制）；NULL/空返回空 Data。
    public func columnBlob(_ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(handle, index))
        guard count > 0, let bytes = sqlite3_column_blob(handle, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

public final class Database {
    private var handle: OpaquePointer?
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        // 索引库含文件名、正文/OCR 文本与向量：目录与库文件都只给属主。
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var pointer: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw SQLiteError.open(url.path, code: code)
        }
        handle = opened
        // SQLite 按 umask 建库（默认 0644）：显式收紧；-wal/-shm 跟随主库权限。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // busy_timeout 必须最先设置：多连接（测试多引擎/App+CLI 并存）瞬时争用直接 SQLITE_BUSY 会打断整条记账链
        try exec("PRAGMA busy_timeout = 5000")
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
    }
    /// 只读连接（WAL 下读写互不阻塞；SQLITE_OPEN_FULLMUTEX 允许多线程共用）。
    /// 供检索热路径使用——绝不与写侧（抽取批处理）共用应用层队列。
    /// 数据库文件尚不存在（首启竞态）返回 nil，调用方回退写连接。
    public static func openReadOnly(url: URL) -> Database? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var pointer: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened = pointer else {
            if let pointer { sqlite3_close(pointer) }
            return nil
        }
        let database = Database(existing: opened, url: url)
        try? database.exec("PRAGMA busy_timeout = 5000")
        return database
    }

    private init(existing: OpaquePointer, url: URL) {
        self.url = url
        handle = existing
    }

    deinit { sqlite3_close(handle) }

    public func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.exec("", sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let prepared = pointer else {
            if let pointer { sqlite3_finalize(pointer) }
            throw SQLiteError.prepare("", sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(handle: prepared, sql: sql)
    }

    public func run(_ sql: String, _ binds: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(binds)
        try statement.step()
    }

    public func query<T>(_ sql: String, _ binds: [SQLiteValue] = [], map: (Statement) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(binds)
        var rows: [T] = []
        while try statement.step() { rows.append(try map(statement)) }
        return rows
    }

    public var lastInsertRowId: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version", map: { Int($0.columnInt(0)) }))?.first ?? 0 }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
