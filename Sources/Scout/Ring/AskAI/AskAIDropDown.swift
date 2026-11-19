import AppKit
import Combine
import SwiftUI

// Ask AI under the CLOSED notch: while an answer streams and nobody is looking at the chat (the notch is shut or
// shows another workspace, and the floating panel is not open), a card drops down with the last lines of the
// answer and the wings show a sparkle with a small spinner. When the answer is done the card stays a few
// seconds with its start. A tap on the card or the wings opens the notch on the Ask AI workspace.

@MainActor
final class AskAIDropDown {
    static let shared = AskAIDropDown()
    static let cardID = "askai.card"
    static let activityID = "askai.live"

    private enum CardState { case none, shown, dismissed }

    private var store: AIChatStore?
    private var center = LiveActivityCenter.shared
    private var navigator = NotchNavigator.shared
    private var cancellables = Set<AnyCancellable>()
    private var wasStreaming = false
    private var chatID: UUID?
    private var cardState = CardState.none
    private var timer: Timer?

    /// Called once for the shared store. `center` and `navigator` are replaceable for the gallery and for tests.
    func attach(_ store: AIChatStore, center: LiveActivityCenter? = nil, navigator: NotchNavigator? = nil) {
        guard self.store == nil else { return }
        self.store = store
        if let center { self.center = center }
        if let navigator { self.navigator = navigator }
        let navigator = self.navigator
        store.$isStreaming.removeDuplicates().sink { [weak self] _ in self?.later() }.store(in: &cancellables)
        navigator.$isOpen.removeDuplicates().sink { [weak self] _ in self?.later() }.store(in: &cancellables)
        navigator.$workspace.removeDuplicates().sink { [weak self] _ in self?.later() }.store(in: &cancellables)
    }

    /// The published values change in `willSet`, so look at the state one turn later.
    private func later() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.update() } }
    }

    /// The owner is reading this chat: in the open notch on the Ask AI workspace, in the floating window, or (a question asked
    /// on the dashboard) in the dashboard's Ask AI panel.
    private var isWatched: Bool {
        if navigator.isOpen, NotchPrefs.resolve(navigator.workspace) == .askAI { return true }
        if navigator.isOpen, AskAIQuick.shared.isOnScreen { return true }
        return Panels.isShown("tool.askai")
    }

    private func update() {
        guard let store else { return }
        // The island only grows for Ask AI while it shows Ask AI.
        if !(navigator.isOpen && navigator.workspace == .askAI) { navigator.releaseHeight(by: .askAI) }   // only Ask AI's own request
        let streaming = store.isStreaming
        if streaming {
            if !wasStreaming {
                chatID = store.streamingChatID ?? store.currentID   // the dashboard's question streams into its own chat
                cardState = .none
                showActivity()
            }
            if isWatched {
                center.dismissCard(id: Self.cardID)
                cardState = .none
            } else if center.cards.contains(where: { $0.id == Self.cardID }) {
                cardState = .shown
            } else if cardState == .shown {
                cardState = .dismissed   // the owner swiped it away: leave it away until the answer is done
            } else if cardState == .none {
                presentCard(duration: 600)
                cardState = .shown
            }
            startTimer()
        } else {
            stopTimer()
            if wasStreaming { finished() } else if isWatched { center.dismissCard(id: Self.cardID) }
        }
        wasStreaming = streaming
    }

    private func finished() {
        guard let store else { return }
        center.dismiss(id: Self.activityID)
        let dismissed = cardState == .dismissed
        cardState = .none
        center.dismissCard(id: Self.cardID)
        guard !isWatched, !dismissed, !store.lastFinishWasStop,
              let chat = store.chats.first(where: { $0.id == chatID }),
              let last = chat.messages.last, last.role == .assistant, !last.text.isEmpty else { return }
        presentCard(duration: last.isError ? 9 : 7)
    }

    private func presentCard(duration: TimeInterval) {
        guard let store else { return }
        let id = chatID
        center.present(NotchCard(id: Self.cardID, kind: .ai, duration: duration, onTap: { AskAIPlace.openNotch(focus: false) }) {
            AskAIDropCard(store: store, chatID: id)
        })
    }

    private func showActivity() {
        guard let store else { return }
        let asked = store.chats.first { $0.id == chatID } ?? store.current
        center.show(Self.activity(question: asked?.messages.last(where: { $0.role == .user })?.text ?? ""))
    }

    /// The wings while an answer streams: a sparkle and a small spinner; resting on the notch shows the question.
    static func activity(question: String) -> LiveActivity {
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? String(localized: "Ask AI")
        return LiveActivity(id: activityID, kind: .ai, expiresAfter: 900, onTap: { AskAIPlace.openNotch(focus: false) }) {
            WingIcon(symbol: "sparkles", tint: Theme.accent)
        } trailing: {
            AIWorkingRing(size: 15).frame(width: 20, height: 20)
        }.withDetail { DemoDetail(title: "Ask AI is answering", subtitle: .verbatim(line)) }
    }

    // A slow check while an answer streams: the floating panel can open or close without telling anyone.
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// The card under the notch. It reads the store itself, so the lines grow as the answer streams.
struct AskAIDropCard: View {
    @ObservedObject var store: AIChatStore
    var chatID: UUID?
    var width: CGFloat = 372
    @Environment(\.colorScheme) private var scheme

    private var chat: AIChat? { store.chats.first { $0.id == chatID } ?? store.current }
    private var answer: AIChatMessage? { chat?.messages.last { $0.role == .assistant } }
    private var question: String { chat?.messages.last { $0.role == .user }?.text ?? "" }
    private var live: Bool { store.isStreaming && answer != nil && store.streamingID == answer?.id }
    private let lineHeight: CGFloat = 15.5
    /// Orange reads on the dark card; on the light one a deeper orange keeps its contrast.
    private var warningInk: Color { scheme == .dark ? .orange : Color(red: 0.78, green: 0.36, blue: 0.0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("Ask AI").font(.system(size: 12, weight: .semibold))
                if let model = answer?.model { Text(AIModels.shortTitle(of: model)).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                status
            }
            let q = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            if !q.isEmpty { Text(q).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            content
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder private var status: some View {
        if live {
            AIWorkingRing(size: 14).frame(width: 16, height: 16)
        } else if answer?.isError == true {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
        }
    }

    @ViewBuilder private var content: some View {
        let text = answer?.text ?? ""
        if answer?.isError == true {
            Text(text).font(.system(size: 12)).foregroundStyle(warningInk).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        } else if live, text.isEmpty {
            Text(store.searching ? "Searching the web…" : "Thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if live {
            // The last four lines: the whole tail is laid out and cut at the top, with a soft fade.
            Text(AIPlain.tail(text, maxChars: 460)).font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width - 28, height: lineHeight * 4, alignment: .bottomLeading)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.14), .init(color: .black, location: 0.42)],
                                     startPoint: .top, endPoint: .bottom))
        } else {
            Text(AIPlain.text(text)).font(.system(size: 12.5)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            Text("Click to read it in the notch").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

/// "Working": a ring that turns. With Reduce Motion on it only breathes (fades in and out).
struct AIWorkingRing: View {
    var size: CGFloat = 15
    @State private var on = false

    var body: some View {
        let calm = ScoutRuntime.reduceMotion
        Circle().trim(from: 0, to: 0.72)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(!calm && on ? 360 : 0))
            .opacity(calm && on ? 0.35 : 1)
            .animation(calm ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .linear(duration: 0.9).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
    }
}

/// Markdown turned into plain lines, for places that cannot draw it (the card under the notch).
enum AIPlain {
    static func text(_ markdown: String) -> String {
        func replace(_ s: String, _ pattern: String, _ template: String) -> String {
            s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        var lines: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }
            var line = raw
            line = replace(line, #"^\s{0,3}#{1,6}\s+"#, "")
            line = replace(line, #"^\s*[-*+]\s+"#, "• ")
            line = replace(line, #"^\s*>\s?"#, "")
            line = replace(line, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
            line = replace(line, #"(\*\*|__|`)"#, "")
            line = replace(line, #"(?<![\*\w])\*(?![\s*])([^*]+)\*"#, "$1")
            lines.append(line)
        }
        var out = lines.joined(separator: "\n")
        out = replace(out, #"\n{2,}"#, "\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The end of the text, starting at a word.
    static func tail(_ markdown: String, maxChars: Int) -> String {
        let plain = text(markdown)
        guard plain.count > maxChars else { return plain }
        let cut = String(plain.suffix(maxChars))
        if let space = cut.firstIndex(where: { $0 == " " || $0 == "\n" }) { return String(cut[cut.index(after: space)...]) }
        return cut
    }
}
