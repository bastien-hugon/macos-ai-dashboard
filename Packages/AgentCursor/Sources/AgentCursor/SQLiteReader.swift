import Foundation
import SQLite3

/// Lecteur SQLite en **lecture seule** de `state.vscdb` (04 · §2, research cursor §2).
/// Ouvre en `mode=ro` sans jamais poser de verrou d'écriture (base de 1 Go en WAL) ;
/// ne lit que des clés ciblées de `ItemTable`/`cursorDiskKV` (jamais de full scan).
final class SQLiteReader {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // file: URI + mode=ro + immutable=1 déconseillé (WAL actif) → mode=ro simple.
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { if let db { sqlite3_close(db) } }

    /// Valeur (BLOB→Data) d'une clé de la table `ItemTable`.
    func itemValue(key: String) -> Data? {
        value(table: "ItemTable", key: key)
    }

    /// Valeur d'une clé de la table `cursorDiskKV`.
    func diskKVValue(key: String) -> Data? {
        value(table: "cursorDiskKV", key: key)
    }

    private func value(table: String, key: String) -> Data? {
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM \(table) WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) // SQLITE_TRANSIENT
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if let bytes = sqlite3_column_blob(stmt, 0) {
            let count = Int(sqlite3_column_bytes(stmt, 0))
            return Data(bytes: bytes, count: count)
        }
        if let text = sqlite3_column_text(stmt, 0) {
            return Data(String(cString: text).utf8)
        }
        return nil
    }

    func stringValue(itemKey: String) -> String? {
        itemValue(key: itemKey).flatMap { String(data: $0, encoding: .utf8) }
    }
}
