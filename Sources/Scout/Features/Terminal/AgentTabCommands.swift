#if !APPSTORE
import Foundation

/// `scout://termtab.*` links for scripted checks. They only start a tab when a test command is set
/// (`SCOUT_TERMTAB_COMMAND` in a scripted run), so a link can never start a real agent.
@MainActor
enum AgentTabCommands {
    static func register() {
        // scout://termtab.new?kind=claude|codex|shell&folder=/path[&open=1]  (open=1 also opens the notch on the new tab)
        DebugCommands.register("termtab.new") { params in
            let store = AgentTabStore.shared
            guard store.commandOverride != nil else { NSLog("Scout: termtab.new needs SCOUT_TERMTAB_COMMAND in a scripted run"); return }
            let kind = AgentTabKind(rawValue: params["kind"] ?? "") ?? .shell
            store.create(kind: kind, folder: params["folder"] ?? NSHomeDirectory(), select: params["open"] == "1")
        }
        // scout://termtab.select?index=0
        DebugCommands.register("termtab.select") { params in
            let store = AgentTabStore.shared
            guard let i = Int(params["index"] ?? "0"), store.tabs.indices.contains(i) else { return }
            store.select(store.tabs[i])
        }
        // scout://termtab.close?index=0 (closes without asking)
        DebugCommands.register("termtab.close") { params in
            let store = AgentTabStore.shared
            guard let i = Int(params["index"] ?? "0"), store.tabs.indices.contains(i) else { return }
            store.close(store.tabs[i])
        }
        // scout://termtab.list?out=/path.json: folder, start time and pid of every tab and every Resume entry.
        DebugCommands.register("termtab.list") { params in
            let store = AgentTabStore.shared
            let rows: [[String: Any]] = store.infos.map {
                ["id": $0.id, "kind": $0.kind.rawValue, "folder": $0.folder, "startedAt": $0.startedAt.timeIntervalSince1970,
                 "running": $0.isRunning, "pid": $0.pid.map { Int($0) } ?? 0]
            } + store.resumable.map {
                ["id": $0.id, "kind": $0.kind.rawValue, "folder": $0.folder, "resume": true]
            }
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("termtab-list.json")
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? data.write(to: out) }
        }
    }
}
#endif
