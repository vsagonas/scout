import AppKit
import SwiftUI

/// `scout://ai.selftest.quick?out=<file>` (headless, its own build: `--automation --headless --run …`, then `kill $PID`).
/// A question asked on the dashboard goes into the one Fast Ask AI conversation, the open chat stays the open one, the
/// conversation stays short, and older questions give up their pictures. Scripted: canned answers, no network, nothing saved.
@MainActor
enum AskAIQuickSelfTest {
    static func register() {
        DebugCommands.register("ai.selftest.quick") { params in
            let out = params["out"].map { URL(fileURLWithPath: $0) } ?? AppPaths.file("ai-quick-selftest.txt")
            Task { @MainActor in
                let lines = await run()
                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            }
        }
    }

    static func run() async -> [String] {
        var lines: [String] = []
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            lines.append("quick selftest \(ok ? "ok  " : "FAIL") \(name)\(ok || detail.isEmpty ? "" : "  (\(detail))")")
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func settle(_ store: AIChatStore) async {
            for _ in 0..<400 where store.isBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
        }

        let store = AIChatStore()
        let open = store.currentID
        let openCount = store.current?.messages.count ?? 0
        let chatsBefore = store.chats.count
        check("before the first question there is no Fast Ask AI conversation", store.quickID == nil)
        // Duplicates left by older builds become ONE Fast Ask AI.
        do {
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            func msg(_ role: AIChatMessage.Role, _ text: String, _ s: Double) -> AIChatMessage {
                var m = AIChatMessage(role: role, text: text)
                m.date = t0.addingTimeInterval(s)
                return m
            }
            var older = AIChat(provider: .anthropic, model: AIModels.autoID)
            older.title = AIChatStore.quickTitle
            older.messages = [msg(.user, "a", 0), msg(.assistant, "A", 1)]
            older.updated = t0.addingTimeInterval(1)
            var newer = AIChat(provider: .anthropic, model: AIModels.autoID)
            newer.title = AIChatStore.quickTitle
            newer.messages = [msg(.user, "c", 20), msg(.assistant, "C", 21)]
            newer.updated = t0.addingTimeInterval(21)
            var middle = AIChat(provider: .anthropic, model: AIModels.autoID)
            middle.title = AIChatStore.quickTitle
            middle.messages = [msg(.user, "b", 10), msg(.assistant, "B", 11)]
            middle.updated = t0.addingTimeInterval(11)
            var other = AIChat(provider: .anthropic, model: AIModels.autoID)
            other.title = "Capital of Peru"
            other.messages = [msg(.user, "Peru?", 5)]
            let three = AIChatStore.mergeQuick([newer, other, middle, older], marked: nil)
            let kept = three.chats.first { $0.id == three.quickID }
            check("three Fast Ask AI chats become one: the newest keeps its place and holds every question and answer in time order; other chats stay",
                  three.chats.count == 2 && three.quickID == newer.id && kept?.messages.map(\.text) == ["a", "A", "b", "B", "c", "C"]
                    && three.chats.contains { $0.id == other.id } && three.chats.first?.id == newer.id,
                  "chats \(three.chats.map(\.title)), texts \(kept?.messages.map(\.text) ?? [])")
            let marked = AIChatStore.mergeQuick([newer, middle, older], marked: older.id)
            check("  the one the marker points at is the one that stays",
                  marked.chats.count == 1 && marked.quickID == older.id && marked.chats.first?.messages.count == 6)
            var long = newer
            long.messages = (0..<30).map { msg($0 % 2 == 0 ? .user : .assistant, "m\($0)", Double(100 + $0)) }
            let capped = AIChatStore.mergeQuick([long, older], marked: nil)
            let first = capped.chats.first { $0.id == capped.quickID }?.messages.first
            check("  merged, it keeps the newest \(AIChatStore.quickLimit) messages and starts on a question",
                  (capped.chats.first { $0.id == capped.quickID }?.messages.count ?? 0) <= AIChatStore.quickLimit && first?.role == .user)
            let single = AIChatStore.mergeQuick([newer, other], marked: nil)
            check("  one Fast Ask AI and other chats: nothing changes", single.chats == [newer, other] && single.quickID == newer.id)
            check("  no Fast Ask AI at all: nothing changes, no conversation", AIChatStore.mergeQuick([other], marked: nil).quickID == nil)
        }

        store.sendQuick(text: "What is the capital of Portugal?", imageFiles: [])
        check("a question asked on the dashboard makes the Fast Ask AI conversation",
              store.quickID != nil && store.quickChat?.title == AIChatStore.quickTitle && store.chats.count == chatsBefore + 1)
        check("  it is the chat being answered, and the open chat stays the open one", store.streamingChatID == store.quickID && store.currentID == open)
        await settle(store)
        check("  the answer lands in it, not in the open chat",
              store.quickChat?.messages.count == 2 && store.quickChat?.messages.last?.role == .assistant
                && !(store.quickChat?.messages.last?.text.isEmpty ?? true) && (store.current?.messages.count ?? 0) == openCount)

        store.sendQuick(text: "And of Spain?", imageFiles: [])
        await settle(store)
        check("the next question goes on in the same conversation, which keeps its name",
              store.quickChat?.messages.count == 4 && store.quickChat?.title == AIChatStore.quickTitle && store.chats.count == chatsBefore + 1)

        store.send(text: "An ordinary question", imageFiles: [])
        await settle(store)
        check("a question in the Ask AI tab still goes to the open chat",
              (store.current?.messages.count ?? 0) == openCount + 2 && store.quickChat?.messages.count == 4 && store.currentID == open)

        store.sendQuick(text: "With a picture", imageFiles: ["sample-a.png"])
        await settle(store)
        check("the newest question keeps its picture", store.quickChat?.messages.contains { !$0.imageFiles.isEmpty } == true)
        store.sendQuick(text: "Another", imageFiles: [])
        await settle(store)
        check("  older questions give theirs up", store.quickChat?.messages.contains { !$0.imageFiles.isEmpty } == false)

        for n in 0..<10 {
            store.sendQuick(text: "Question \(n)", imageFiles: [])
            await settle(store)
        }
        let kept = store.quickChat?.messages ?? []
        check("the conversation stays short and always starts with a question",
              kept.count <= AIChatStore.quickLimit && kept.count >= AIChatStore.quickLimit - 2 && kept.first?.role == .user && kept.last?.role == .assistant, "\(kept.count)")
        check("  the newest question is still there", kept.contains { $0.text == "Question 9" })

        let quickBefore = store.quickID
        if let id = store.quickID { store.delete(id) }
        check("a chat list cannot delete it (the dashboard keeps its history)", store.quickID != nil && store.quickID == quickBefore && !(store.quickChat?.messages.isEmpty ?? true))
        store.newChat()
        store.clearAll()
        check("  nor does Clear all chats: it keeps Fast Ask AI and its history", store.quickID == quickBefore && !(store.quickChat?.messages.isEmpty ?? true) && store.chats.count == 1, "\(store.chats.count) chats")
        store.clearQuick()
        check("its own Clear empties it and keeps the conversation's place", store.quickID == quickBefore && (store.quickChat?.messages.isEmpty ?? false))
        store.sendQuick(text: "Fresh start", imageFiles: [])
        await settle(store)
        check("  and the next dashboard question starts a new one", store.quickChat?.messages.count == 2 && store.quickChat?.title == AIChatStore.quickTitle)

        let quick = AskAIQuick.shared
        quick.hide()
        quick.show()
        let shown = quick.showing
        quick.toggle()
        check("the answer strip shows when asked for and hides again", shown && !quick.showing)

        // The dashboard's Ask AI line and the answer strip, in the 8-bit look and in the minimal look: drawn (and the two looks differ), the real field
        // takes typed text, the Screen key switches Monitor, the send key sends into Fast Ask AI, the strip's hide key hides it.
        let savedLook = UserDefaults.standard.object(forKey: Retro.styleKey)
        let savedMonitor = UserDefaults.standard.object(forKey: AIMonitor.key)
        var linePictures: [Bool: Data] = [:], stripPictures: [Bool: Data] = [:]
        for eightBit in [true, false] {
            Pref.set(eightBit, Retro.styleKey)
            let look = eightBit ? "[8-bit look] " : "[minimal look] "
            UserDefaults.standard.set(false, forKey: AIMonitor.key)
            let lineStore = AIChatStore()
            let draft = AskAINotchDraft()
            let line = MiniBoomRig(AnyView(AskAIWidgetView(store: lineStore, draft: draft)), size: CGSize(width: 4 * NookMetrics.cell, height: NookMetrics.widgetHeight))
            await pause(0.7)
            check(look + "the Ask AI line draws in this look", Retro.is8bit == eightBit && (line.picture()?.busy ?? 0) > 400)
            linePictures[eightBit] = line.picture()?.bytes
            let row = line.controls.first
            if let row, let field = line.firstTextField() {
                line.panel.makeFirstResponder(field)
                (field.currentEditor() as? NSTextView)?.insertText("What is the capital of Portugal?", replacementRange: NSRange(location: 0, length: 0))
                await pause(0.3)
                check(look + "  the real field takes typed text and the line can send it", draft.text == "What is the capital of Portugal?" && draft.canSend, "draft \"\(draft.text)\"")
                await line.click(CGRect(x: row.minX + 13, y: row.midY, width: 0, height: 0))   // the Screen key at the left end
                let monitorOn = AIMonitor.isOn
                await line.click(CGRect(x: row.minX + 13, y: row.midY, width: 0, height: 0))
                check(look + "  the Screen key switches Monitor on, and off again", monitorOn && !AIMonitor.isOn)
                let keys = line.controls.filter { $0.width < 40 }.sorted { $0.midX > $1.midX }
                if let send = keys.first {
                    await line.click(send)
                    await pause(0.4)
                    let q = lineStore.quickChat
                    check(look + "  a real click on the send key puts the question into Fast Ask AI; the answer stays in the panel (no strip)",
                          q?.title == AIChatStore.quickTitle && q?.messages.first?.text == "What is the capital of Portugal?" && !AskAIQuick.shared.showing && draft.text.isEmpty,
                          "quick \(String(describing: q?.messages.first?.text)), showing \(AskAIQuick.shared.showing), draft \"\(draft.text)\"")
                } else {
                    check(look + "  the send key is findable as a control", false, "controls \(line.controls.map { $0.size })")
                }
                await settle(lineStore)
            } else {
                check(look + "  the Ask AI line has its field and its controls", false, "controls \(line.controls.count)")
            }
            line.close()

            let demo = AIChatStore(demo: .conversation)
            AskAIQuick.shared.show()
            let strip = MiniBoomRig(AnyView(AskAIQuickStrip(preview: demo.chats.first.map { AskAIQuickPreview(store: demo, chat: $0) })),
                                    size: CGSize(width: 1100, height: AskAIQuick.stripHeight))
            await pause(0.7)
            check(look + "the answer strip draws in this look", Retro.is8bit == eightBit && (strip.picture()?.busy ?? 0) > 2000)
            stripPictures[eightBit] = strip.picture()?.bytes
            let buttons = strip.controls.sorted { $0.midX > $1.midX }
            if let hide = buttons.first, buttons.count >= 2 {
                await strip.click(hide)
                check(look + "  the strip's hide key hides it (it has Open in Ask AI beside it)", !AskAIQuick.shared.showing)
            } else {
                check(look + "  the strip's keys are findable as controls", false, "controls \(buttons.count)")
            }
            strip.close()
            AskAIQuick.shared.hide()
        }
        Pref.set(savedLook, Retro.styleKey)
        UserDefaults.standard.set(savedMonitor, forKey: AIMonitor.key)
        check("the Ask AI line and the answer strip each look different in the minimal look than in the 8-bit one",
              linePictures[true] != nil && linePictures[false] != nil && linePictures[true] != linePictures[false]
                && stripPictures[true] != nil && stripPictures[false] != nil && stripPictures[true] != stripPictures[false])

        lines.append("quick selftest done: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
        return lines
    }
}
