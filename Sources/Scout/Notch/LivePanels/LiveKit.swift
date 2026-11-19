import Combine
import SwiftUI

// Shared pieces of the live panels: a feed that follows one service as a plain value, the panel frame (title line +
// content), and the small buttons. Panels show up on the dashboard only while something is happening on the Mac.

/// One service's state as an Equatable snapshot. A real feed re-reads the service after it says it changed; a manual
/// feed (galleries, self-tests) is set by hand. `changes` fires only when the snapshot really differs, after it is set.
@MainActor
final class LiveFeed<Value: Equatable>: ObservableObject {
    @Published private(set) var value: Value

    private let read: (() -> Value)?
    private let merge: ((_ old: Value, _ new: Value) -> Value)?
    private let changed = PassthroughSubject<Void, Never>()
    private var bag = Set<AnyCancellable>()

    var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }

    /// Follows a service: `read` runs again after each of `triggers` (delivered on the main queue, after the change).
    /// `merge` may carry facts across two snapshots (a download that just finished).
    init(read: @escaping () -> Value, triggers: [AnyPublisher<Void, Never>], merge: ((Value, Value) -> Value)? = nil) {
        self.read = read
        self.merge = merge
        value = read()
        for trigger in triggers {
            trigger.receive(on: DispatchQueue.main).sink { [weak self] in self?.refresh() }.store(in: &bag)
        }
    }

    /// A feed set by hand.
    init(_ value: Value, merge: ((Value, Value) -> Value)? = nil) {
        read = nil
        self.merge = merge
        self.value = value
    }

    func refresh() { if let read { set(read()) } }

    func set(_ new: Value) {
        let next = merge?(value, new) ?? new
        guard next != value else { return }
        value = next
        changed.send()
    }
}

extension ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    /// Fires when the object is about to change; `LiveFeed` hops to the next main-queue turn before it reads.
    var liveTrigger: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
}

/// What the coordinator needs beyond `LivePanelSource`: a signal when the panel's state changed, and the next moment
/// its liveness or priority can flip by the clock alone (a meeting entering its hour, a Done line running out).
@MainActor
protocol LiveDriven: LivePanelSource {
    var changes: AnyPublisher<Void, Never> { get }
    func nextWake(after now: Date) -> Date?
}

extension LiveDriven {
    var changes: AnyPublisher<Void, Never> { Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher() }
    func nextWake(after now: Date) -> Date? { nil }
}

// MARK: - Look

/// The frame every live panel shares with the dashboard's widgets: a small title line (accent symbol, 11 pt semibold
/// title, a grey fact on the right) over the content, 10 pt padding, filling the 140 pt cell.
struct LivePanelFrame<Trailing: View, Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    var tint: Color = Theme.accent
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                trailing()
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension LivePanelFrame where Trailing == EmptyView {
    init(symbol: String, title: LocalizedStringKey, tint: Color = Theme.accent, @ViewBuilder content: @escaping () -> Content) {
        self.init(symbol: symbol, title: title, tint: tint, trailing: { EmptyView() }, content: content)
    }
}

/// The grey fact at the right of a title line ("2 active", "+1 more").
struct LiveTitleFact: View {
    let text: Text
    var color: Color = .secondary

    /// `LiveTitleFact(text: "2 active")` localizes a literal; `LiveTitleFact(verbatim: fact)` shows a string already made.
    init(text: LocalizedStringKey, color: Color = .secondary) { self.text = Text(text); self.color = color }
    init(verbatim: String, color: Color = .secondary) { self.text = Text(verbatim: verbatim); self.color = color }

    var body: some View {
        text.font(.system(size: 10)).foregroundStyle(color).lineLimit(1)
    }
}

/// A small capsule button. `fill` nil = the quiet grey one; otherwise a solid colour with `ink` text.
struct LivePillStyle: ButtonStyle {
    var fill: Color?
    var ink: Color = .black.opacity(0.85)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(fill == nil ? Color.primary : ink)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(fill ?? Color.primary.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// A round icon button (pause / resume).
struct LiveRoundStyle: ButtonStyle {
    var fill: Color?
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(fill == nil ? Color.primary : Color.black.opacity(0.85))
            .frame(width: size, height: size)
            .background(Circle().fill(fill ?? Color.primary.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

extension View {
    /// Marks a button of a live panel, so that a pointer resting on it never opens the panel by itself (the dashboard's
    /// `nookControl()` marker).
    func liveControl() -> some View { nookControl() }
}

/// A thin progress bar (4 pt). `fraction` nil = unknown: a short capsule that glides (a still one with Reduce Motion).
struct LiveBar: View {
    var fraction: Double?
    var tint: Color = Theme.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                if let fraction {
                    Capsule().fill(tint).frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                } else if ScoutRuntime.reduceMotion || ScoutRuntime.isGallery {
                    Capsule().fill(tint).frame(width: geo.size.width * 0.3)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                        let t = (ctx.date.timeIntervalSinceReferenceDate / 1.3).truncatingRemainder(dividingBy: 1)
                        let w = geo.size.width * 0.3
                        Capsule().fill(tint).frame(width: w).offset(x: (geo.size.width - w) * (0.5 - 0.5 * cos(t * 2 * .pi)))
                    }
                }
            }
        }
        .frame(height: height)
    }
}

enum LiveFormat {
    /// "12 min", "1 hr, 20 min", "2 hr" (as the person's language writes them): whole minutes.
    static func duration(minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)"
    }

    /// "12 min", "1 hr, 20 min", "2 hr": whole minutes, rounded up.
    static func span(_ seconds: TimeInterval) -> String {
        duration(minutes: max(1, Int((seconds / 60).rounded(.up))))
    }

    static func percent(_ fraction: Double) -> String { String(localized: "\(Int((min(1, max(0, fraction)) * 100).rounded())) %") }
}
