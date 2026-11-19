#if !APPSTORE
import SQLite3
import SwiftUI

@MainActor
enum MessagesFeature {
    static func start() {
        MessagesService.shared.start()
        DebugCommands.register("message.demo") { _ in MessagesService.shared.demo() }
    }

    static func registerSelfTests() {
        FeaturesSelfTest.add("messages: attributedBody typedstream decoding") {
            for text in ["Hi", "Are we still on for dinner at 7?", "Ünïcødé and emoji 🎉 ok", String(repeating: "long text ", count: 40)] {
                guard TypedStream.string(from: TypedStream.makeSample(text)) == text else { print("  failed: \(text.prefix(20))"); return false }
            }
            return TypedStream.string(from: Data([1, 2, 3])) == nil && TypedStream.string(from: Data("NSString".utf8)) == nil
        }
        FeaturesSelfTest.add("messages: reads a database like chat.db (text, attributedBody, groups, skips mine and tapbacks)") {
            let path = AppPaths.folder("SelfTest").appendingPathComponent("fake-chat.db").path
            try? FileManager.default.removeItem(atPath: path)
            var db: OpaquePointer?
            guard sqlite3_open(path, &db) == SQLITE_OK else { return false }
            let blob = TypedStream.makeSample("Typed stream hello")
            let schema = """
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, handle_id INTEGER, is_from_me INTEGER, date INTEGER, associated_message_type INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, style INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            INSERT INTO handle VALUES (1, '+15551230101'), (2, 'maya@example.com');
            INSERT INTO chat VALUES (1, 'iMessage;-;+15551230101', '', 45), (2, 'iMessage;+;chat123', 'Weekend plans', 43);
            INSERT INTO message (ROWID, text, handle_id, is_from_me, date) VALUES (1, 'old message', 1, 0, 700000000000000000);
            INSERT INTO message (ROWID, text, handle_id, is_from_me, date) VALUES (2, 'plain text', 1, 0, 700000000000000000);
            INSERT INTO message (ROWID, text, handle_id, is_from_me, date) VALUES (3, 'my own message', 1, 1, 700000000000000000);
            INSERT INTO message (ROWID, text, handle_id, is_from_me, date, associated_message_type) VALUES (5, 'Loved "plain text"', 1, 0, 700000000000000000, 2000);
            INSERT INTO message (ROWID, text, handle_id, is_from_me, date, cache_has_attachments) VALUES (6, '\u{FFFC}', 2, 0, 700000000000000000, 1);
            INSERT INTO chat_message_join VALUES (1, 1), (1, 2), (1, 3), (1, 5), (2, 6);
            """
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); return false }
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO message (ROWID, text, attributedBody, handle_id, is_from_me, date) VALUES (4, NULL, ?, 2, 0, 700000000000000000)", -1, &stmt, nil)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            sqlite3_exec(db, "INSERT INTO chat_message_join VALUES (2, 4);", nil, nil, nil)
            sqlite3_close(db)
            guard let reader = ChatDB(path: path), reader.maxRowID() == 6 else { print("  could not open"); return false }
            let found = reader.messages(after: 1)
            let ids = found.map(\.id)
            guard ids == [2, 4, 6] else { print("  ids \(ids)"); return false }
            return found[0].text == "plain text" && found[0].chatGUID == "iMessage;-;+15551230101" && !found[0].isGroup
                && found[1].text == "Typed stream hello" && found[1].isGroup && found[1].groupName == "Weekend plans" && found[1].handle == "maya@example.com"
                && found[2].text == "Attachment" && found[2].hasAttachment
        }
        FeaturesSelfTest.add("messages: the reply script escapes quotes and never runs in tests") {
            let script = MessagesService.sendScript(text: "She said \"hi\" \\ ok", chatGUID: "iMessage;-;+1555")
            return script.contains("send \"She said \\\"hi\\\" \\\\ ok\" to theChat") && script.contains("chat id \"iMessage;-;+1555\"")
        }
    }

    static func registerGallery() {
        let sample = IncomingMessage(id: -1, text: "Are we still on for dinner at 7? I booked the corner table.", handle: "Maya Chen", chatGUID: nil,
                                     groupName: nil, isGroup: false, date: Date(), hasAttachment: false)
        Gallery.register("messages-card", size: CGSize(width: 440, height: 170)) {
            MessageCardView(model: MessageCardModel(message: sample, showText: true)).background(GlassBackground(cornerRadius: 22))
        }
        Gallery.register("messages-card-hidden-text", size: CGSize(width: 440, height: 170)) {
            MessageCardView(model: MessageCardModel(message: sample, showText: false)).background(GlassBackground(cornerRadius: 22))
        }
        Gallery.register("messages-card-group", size: CGSize(width: 440, height: 170)) {
            var group = sample
            group.groupName = "Weekend plans"
            return MessageCardView(model: MessageCardModel(message: group, showText: true)).background(GlassBackground(cornerRadius: 22))
        }
        FeatureGallery.settings("settings-messages", height: 780) { MessagesSettingsPane() }
    }
}
#endif
