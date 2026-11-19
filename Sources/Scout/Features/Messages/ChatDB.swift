#if !APPSTORE
import Foundation
import SQLite3

struct IncomingMessage: Identifiable, Equatable {
    var id: Int64                 // the message ROWID
    var text: String
    var handle: String            // phone number or email of the sender
    var chatGUID: String?         // e.g. "iMessage;-;+15551234567": used to answer
    var groupName: String?        // set for group chats
    var isGroup: Bool
    var date: Date
    var hasAttachment: Bool
}

/// Reads Messages' own database (read-only). Needs Full Disk Access; nothing else is touched.
final class ChatDB: @unchecked Sendable {
    static var defaultPath: String { NSHomeDirectory() + "/Library/Messages/chat.db" }

    private var db: OpaquePointer?

    /// Fails (nil) when the file can't be opened, which is what a missing Full Disk Access looks like.
    init?(path: String = ChatDB.defaultPath) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        sqlite3_busy_timeout(db, 500)
        // A protected file opens lazily: the first query shows whether we really may read it.
        guard maxRowID() != nil else { sqlite3_close(db); return nil }
    }

    deinit { sqlite3_close(db) }

    func maxRowID() -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(ROWID), 0) FROM message", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    /// Messages from other people after `rowID` (tapbacks and empty rows skipped), oldest first.
    func messages(after rowID: Int64, limit: Int = 20) -> [IncomingMessage] {
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, h.id, c.guid, c.display_name, c.style, m.date, m.cache_has_attachments
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join j ON j.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = j.chat_id
        WHERE m.ROWID > ? AND m.is_from_me = 0 AND (m.associated_message_type IS NULL OR m.associated_message_type = 0)
        ORDER BY m.ROWID LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowID)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var result: [IncomingMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            var text = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 1))
            if text == nil || text?.isEmpty == true, sqlite3_column_type(stmt, 2) == SQLITE_BLOB, let bytes = sqlite3_column_blob(stmt, 2) {
                text = TypedStream.string(from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 2))))
            }
            let attachment = sqlite3_column_int(stmt, 8) != 0
            let cleaned = (text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty && !attachment { continue }
            let handle = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, 3))
            let guid = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
            let name = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 5))
            let style = sqlite3_column_int(stmt, 6)      // 43 = group chat, 45 = one to one
            let raw = sqlite3_column_int64(stmt, 7)
            let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
            result.append(IncomingMessage(id: id, text: cleaned.isEmpty ? String(localized: "Attachment") : cleaned, handle: handle, chatGUID: guid,
                                          groupName: (name?.isEmpty == false) ? name : nil, isGroup: style == 43,
                                          date: Date(timeIntervalSinceReferenceDate: seconds), hasAttachment: attachment && cleaned.isEmpty))
        }
        return result
    }
}

/// Messages stores most texts only inside `attributedBody`: an Apple "typedstream" holding an NSAttributedString.
/// The string sits after the class name `NSString`, behind a `+` marker and a length (1, 3 or 5 bytes).
/// Decoded by hand: NSUnarchiver would raise an Objective-C exception on odd data.
enum TypedStream {
    static func string(from data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard bytes.count > marker.count + 4, let at = find(marker, in: bytes) else { return nil }
        var i = at + marker.count
        let limit = min(bytes.count, i + 16)
        while i < limit, bytes[i] != 0x2B { i += 1 }
        guard i < limit else { return nil }
        i += 1
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i])
        i += 1
        if length == 0x81 {
            guard i + 2 <= bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
        } else if length == 0x82 {
            guard i + 4 <= bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
            i += 4
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for start in 0...(hay.count - needle.count) where hay[start] == needle[0] {
            if Array(hay[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    /// Builds the bytes Messages writes for a text (used by self-tests).
    static func makeSample(_ text: String) -> Data {
        var d = Data([0x04, 0x0B]) + Data("streamtyped".utf8) + Data([0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12])
        d += Data("NSAttributedString".utf8) + Data([0x00, 0x84, 0x84, 0x08]) + Data("NSObject".utf8) + Data([0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08])
        d += Data("NSString".utf8) + Data([0x01, 0x94, 0x84, 0x01, 0x2B])
        let utf8 = Array(text.utf8)
        if utf8.count < 0x81 { d.append(UInt8(utf8.count)) }
        else if utf8.count <= 0xFFFF { d += Data([0x81, UInt8(utf8.count & 0xFF), UInt8(utf8.count >> 8)]) }
        else { d += Data([0x82, UInt8(utf8.count & 0xFF), UInt8((utf8.count >> 8) & 0xFF), UInt8((utf8.count >> 16) & 0xFF), UInt8(utf8.count >> 24)]) }
        d += Data(utf8) + Data([0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x05, 0x92, 0x84, 0x84, 0x84, 0x0C])
        d += Data("NSDictionary".utf8) + Data([0x00, 0x94, 0x84, 0x01, 0x69, 0x01, 0x92, 0x84, 0x96, 0x96, 0x1D])
        return d
    }
}
#endif
