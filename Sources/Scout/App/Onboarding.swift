import AppKit
import SwiftUI

// The welcome tour
//   1 Welcome · 2 Pick your look (8-bit or Minimal, two big pictures) · 3 Pick a size (Normal, Large, Extra large) · 4 Pick your colours
//   (Dark, Light colourful) · 5 the notch · 6 permissions · 7 done. (The ring's page went with the ring, 2026-11-16.)
// The pictures are the app's own dashboard drawn by the gallery with sample data (Support/Resources/tour-*.png); a pick writes its setting at
// once (Retro.styleKey, Look.scaleKey, Look.presetKey) and the pictures, the window itself and the whole app follow. Big type, large click
// targets, Return = continue, the arrow keys choose, Reduce Motion: fades only. Replayable from Settings > General > Show.

/// An ordinary Scout window that can be told to stay where it is put (self-tests keep theirs offscreen; AppKit would pull a titled window back
/// onto a screen when it is shown).
final class ScoutWindow: NSWindow {
    var allowsOffscreen = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// The welcome tour's window. It opens in the middle of the screen it opens on, grows and shrinks around its middle with the size pick (as far as
/// the screen allows) and is never partly off the screen
@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private var window: ScoutWindow?
    private var model: OnboardingModel?
    private var monitor: Any?
    private let roomOf: ((NSWindow?) -> CGRect)?
    private let front: (NSWindow) -> Void
    private let offscreen: Bool
    /// The window, for the self-test.
    var currentWindow: NSWindow? { window }
    var currentModel: OnboardingModel? { model }

    /// `room` answers "where may the window sit" (the visible frame of a screen) for the window, or nil before it exists; the default is the
    /// screen it is on, else the screen with the pointer, else the main one. Self-tests give a room of their own, their own way to bring the
    /// window forward, and `offscreen` so it stays where they put it.
    init(room: ((NSWindow?) -> CGRect)? = nil, front: ((NSWindow) -> Void)? = nil, offscreen: Bool = false) {
        roomOf = room
        self.front = front ?? { WindowFront.show($0) }
        self.offscreen = offscreen
    }

    /// The visible frame the window sits in now (a window on show keeps its own screen; a new one takes the screen under the pointer).
    func room(for window: NSWindow?) -> CGRect {
        if let roomOf { return roomOf(window) }
        let shown = window.flatMap { $0.isVisible ? $0.screen : nil }
        let pointer = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        return (shown ?? pointer ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func show(page: Int = 0) {
        if window == nil {
            let w = ScoutWindow(contentRect: CGRect(x: 0, y: 0, width: OnboardingView.baseSize.width, height: OnboardingView.baseSize.height),
                                styleMask: [.titled, .closable, .fullSizeContentView],
                                backing: .buffered, defer: false)
            w.allowsOffscreen = offscreen
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            // On top of every window, Settings and the open notch too, until the tour is finished or closed
            w.level = Self.level
            w.collectionBehavior.insert(.fullScreenAuxiliary)
            window = w
        }
        let model = OnboardingModel(page: page)
        self.model = model
        window?.contentView = NSHostingView(rootView: OnboardingView(model: model, onFinish: { [weak self] in self?.finish() },
                                                                      onResize: { [weak self] _ in self?.refit(keepingMiddle: true) }))
        refit(keepingMiddle: false)   // sized for the size pick and put in the middle of its screen before it shows
        installKeys()
        if let window { front(window) }
    }

    /// Above Settings (which itself stands above the open notch).
    static let level = NSWindow.Level(rawValue: SettingsNotchHold.aboveNotch.rawValue + 1)

    func finish() {
        Pref.set(true, "app.onboarded")
        removeKeys()
        window?.close()
        window = nil
        model = nil
    }

    /// Sizes the window for the size pick and the room its screen has, then places it: in the middle of the room when it opens, around its own
    /// middle when it changes size (so a window the person moved stays where they put it), and always inside the room.
    private func refit(keepingMiddle: Bool) {
        guard let window, let model else { return }
        let room = room(for: window)
        model.room = room.size
        // A window the person moved keeps its middle; one that is still in the middle of the room goes back to the exact middle (a window's origin
        // rounds to whole points, so keeping the middle of a centred window would drift a point or two with every size pick). Read before the size
        // changes: the window keeps its top left corner then.
        let now = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let centred = abs(now.x - room.midX) <= 3 && abs(now.y - room.midY) <= 3
        let kept: CGPoint? = keepingMiddle && window.isVisible && !centred ? now : nil
        window.setContentSize(Self.contentSize(for: window, layout: OnboardingView.windowSize(for: Look.size, room: room.size)))
        let size = window.frame.size
        window.setFrame(Self.placed(size: size, middle: kept ?? CGPoint(x: room.midX, y: room.midY), in: room), display: true)
    }

    /// A frame of `size` around `middle`, moved just far enough to lie inside `room` (a window bigger than the room keeps its top edge in it).
    static func placed(size: CGSize, middle: CGPoint, in room: CGRect) -> CGRect {
        var x = middle.x - size.width / 2, y = middle.y - size.height / 2
        x = min(max(x, room.minX), max(room.minX, room.maxX - size.width))
        y = min(max(y, room.minY), max(room.minY, room.maxY - size.height))
        if size.height > room.height { y = room.maxY - size.height }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The content view's size for a layout of `layout` points: the layout plus the transparent title bar the content sits under.
    static func contentSize(for window: NSWindow, layout: CGSize) -> CGSize {
        CGSize(width: layout.width, height: layout.height + max(0, window.frame.height - window.contentLayoutRect.height))
    }

    /// Arrow keys choose on the picking pages (Return is the Continue button's own shortcut).
    private func installKeys() {
        removeKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            switch event.keyCode {
            case 123, 126: return self.model?.arrow(-1) == true ? nil : event   // left, up
            case 124, 125: return self.model?.arrow(1) == true ? nil : event   // right, down
            default: return event
            }
        }
    }

    private func removeKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The tour's state: the page, and where the cards are (self-tests click them).
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var page: Int
    /// The picking pages' choices in order (the arrow keys walk them).
    static let lookChoices = [true, false]   // 8-bit, minimal
    /// Cards and keys by name, in the tour's own points (before the window's scaling).
    var rects: [String: CGRect] = [:]
    /// How much the window draws bigger than its base size now.
    var scale: CGFloat = 1
    /// The room the window has on its screen (the size of its visible frame); nil = no limit (galleries and self-tests).
    @Published var room: CGSize?

    init(page: Int = 0) { self.page = page }

    /// An arrow key on a picking page moves the choice by `delta`. Returns true when it did something (the key is used up).
    @discardableResult
    func arrow(_ delta: Int) -> Bool {
        switch page {
        case OnboardingView.lookPage:
            let all = Self.lookChoices
            let now = all.firstIndex(of: Retro.is8bit) ?? 0
            let next = min(all.count - 1, max(0, now + delta))
            Pref.set(all[next], Retro.styleKey)
            return true
        case OnboardingView.sizePage:
            let all = Look.Size.allCases
            let now = all.firstIndex(of: Look.size) ?? 0
            Pref.set(all[min(all.count - 1, max(0, now + delta))].rawValue, Look.scaleKey)
            return true
        case OnboardingView.colourPage:
            let all = Look.Preset.allCases
            let now = all.firstIndex(of: Look.preset) ?? 0
            let picked = all[min(all.count - 1, max(0, now + delta))]
            Pref.set(picked.rawValue, Look.presetKey)
            if !ScoutRuntime.isScripted, let one = AppAppearance(rawValue: picked.rawValue) { AppAppearance.set(one) }   // the one light/dark setting
            return true
        default:
            return false
        }
    }
}

private struct TourRectKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private extension View {
    /// Reports this view's frame by name (the tour's own space), for self-tests.
    func tourRect(_ name: String) -> some View {
        background(GeometryReader { Color.clear.preference(key: TourRectKey.self, value: [name: $0.frame(in: .named("tour"))]) })
    }
}

struct OnboardingView: View {
    @StateObject private var model: OnboardingModel
    var onFinish: () -> Void
    var onResize: (CGSize) -> Void

    @AppStorage(Retro.styleKey) private var eightBit = true
    @AppStorage(Look.scaleKey) private var sizeRaw = Look.Size.normal.rawValue
    @AppStorage(Look.presetKey) private var presetRaw = Look.Preset.dark.rawValue

    static let pageCount = 7
    static let lookPage = 1, sizePage = 2, colourPage = 3
    /// The window at normal size; it grows with the size pick (as far as the screen allows).
    static let baseSize = CGSize(width: 920, height: 660)

    /// The window's size now: the base times the size pick, as big as the screen has room for.
    static func windowSize(for size: Look.Size = Look.size, screen: NSScreen? = ScoutRuntime.isScripted ? nil : NSScreen.main) -> CGSize {
        windowSize(for: size, room: screen?.visibleFrame.size)
    }

    /// The same for a room of this size (the visible frame of the screen the window is on); nil = no limit.
    static func windowSize(for size: Look.Size, room: CGSize?) -> CGSize {
        let s = scale(for: size, room: room)
        return CGSize(width: baseSize.width * s, height: baseSize.height * s)
    }

    static func scale(for size: Look.Size, screen: NSScreen?) -> CGFloat { scale(for: size, room: screen?.visibleFrame.size) }

    /// How much bigger than the base the window is drawn: the size pick's factor, cut down so the window (its title bar too) keeps 20 points of the
    /// room around it. On a small screen it is drawn smaller than the base (never under 0.6) rather than hang off the screen.
    static func scale(for size: Look.Size, room: CGSize?) -> CGFloat {
        guard let room else { return size.factor }
        return max(0.6, min(size.factor, (room.width - 40) / baseSize.width, (room.height - 40 - titleBarAllowance) / baseSize.height))
    }

    /// More than the transparent title bar the layout sits under (about 28 points on today's macOS).
    static let titleBarAllowance: CGFloat = 36

    init(initialPage: Int = 0, model: OnboardingModel? = nil, onFinish: @escaping () -> Void = {}, onResize: @escaping (CGSize) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: model ?? OnboardingModel(page: initialPage))
        self.onFinish = onFinish
        self.onResize = onResize
    }

    // The effective settings (a forced look in a gallery run wins); reading the stored values first makes the view follow every pick.
    private var size: Look.Size { _ = sizeRaw; return Look.size }
    private var preset: Look.Preset { _ = presetRaw; return Look.preset }
    private var is8bit: Bool { _ = eightBit; return Retro.is8bit }
    /// The room comes from the window that shows the tour (its own screen's visible frame); without a window (galleries, self-tests) there is no limit.
    private var scale: CGFloat { Self.scale(for: size, room: model.room) }

    var body: some View {
        content
            .frame(width: Self.baseSize.width, height: Self.baseSize.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: Self.baseSize.width * scale, height: Self.baseSize.height * scale, alignment: .topLeading)
            .onAppear { model.scale = scale }
            .onChange(of: model.room) { model.scale = scale }
            .onChange(of: sizeRaw) {
                model.scale = scale
                onResize(Self.windowSize(for: size, room: model.room))
            }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.page {
                case 0: WelcomePage()
                case Self.lookPage: LookPage(eightBit: Binding(get: { is8bit }, set: { eightBit = $0 }), preset: preset)
                case Self.sizePage: SizePage(size: size, eightBit: is8bit, preset: preset, pick: { sizeRaw = $0.rawValue })
                case Self.colourPage: ColourPage(preset: preset, eightBit: is8bit, pick: { picked in
                    presetRaw = picked.rawValue
                    if !ScoutRuntime.isScripted, let one = AppAppearance(rawValue: picked.rawValue) { AppAppearance.set(one) }   // the one light/dark setting
                })
                case 4: NotchPage()
                case 5: PermissionsPage()
                default: DonePage()
                }
            }
            .id(model.page)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Button("Back") { go(model.page - 1) }
                    .buttonStyle(TourButtonStyle(prominent: false))
                    .opacity(model.page == 0 ? 0 : 1)
                    .disabled(model.page == 0)
                    .tourRect("back")
                Spacer()
                HStack(spacing: 9) {
                    ForEach(0..<Self.pageCount, id: \.self) { i in
                        Circle().fill(i == model.page ? Theme.accent : Color.primary.opacity(0.2)).frame(width: 9, height: 9)
                    }
                }
                .accessibilityHidden(true)
                Spacer()
                if model.page < Self.pageCount - 1 {
                    Button("Continue") { go(model.page + 1) }
                        .buttonStyle(TourButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .tourRect("next")
                } else {
                    Button("Start using Scout") { onFinish() }
                        .buttonStyle(TourButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .tourRect("next")
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 26)
            .padding(.top, 8)
        }
        .coordinateSpace(name: "tour")
        .onPreferenceChange(TourRectKey.self) { model.rects = $0 }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func go(_ new: Int) {
        guard new >= 0, new < Self.pageCount else { return }
        withAnimation(ScoutRuntime.reduceMotion ? nil : Theme.quick) { model.page = new }
    }
}

/// A big key for the tour's footer: 46 pt tall, easy to hit.
private struct TourButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.88) : Color.primary)
            .padding(.horizontal, 26)
            .frame(minWidth: 120, minHeight: 46)
            .background(Capsule().fill(prominent ? Theme.accent : Color.primary.opacity(0.10)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - The pictures

/// One of the tour's pictures of the open dashboard (`tour-8bit-dark`, `tour-8bit-light`, `tour-min-dark`, `tour-min-light`).
enum TourPictures {
    private static var cache: [String: NSImage] = [:]

    static func name(eightBit: Bool, preset: Look.Preset) -> String { "tour-\(eightBit ? "8bit" : "min")-\(preset.rawValue)" }

    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

/// The picture at `width`, whole (the island's own rounded bottom) or only its left part (the keys, the agents and the Ask AI line) at a
/// bigger scale so a card can show it large.
private struct TourPicture: View {
    let name: String
    var width: CGFloat
    /// Show only the left `portion` of the picture (nil: all of it).
    var portion: CGFloat?

    /// The picture's own shape (the island exactly: `LookGallery.pictureWidth` by `pictureHeight`), read from the picture itself.
    private var aspect: CGFloat {
        guard let size = TourPictures.image(name)?.size, size.width > 0 else { return LookGallery.pictureHeight / LookGallery.pictureWidth }
        return size.height / size.width
    }

    var body: some View {
        let fullWidth = width / (portion ?? 1)
        let height = fullWidth * aspect
        Group {
            if let image = TourPictures.image(name) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: fullWidth, height: height)
                    .frame(width: width, height: height, alignment: .leading)
                    // Only its left part: the island's own round corner is transparent in the picture and showed the window behind as a cut
                    // wedge in the card's corner.
                    // The picture's own surface fills it.
                    .background(portion == nil ? Color.clear : (name.hasSuffix("-light") ? Look.paper : Color.black))
                    .clipShape(portion == nil
                               ? AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: 26 * fullWidth / LookGallery.pictureWidth, bottomTrailingRadius: 26 * fullWidth / LookGallery.pictureWidth))
                               : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.1))
                    .frame(width: width, height: height)
                    .overlay(Text("Picture").foregroundStyle(.secondary))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A big choice card: a picture, a name and a line, marked when it is the pick. The whole card is the click target.
private struct TourCard: View {
    let id: String
    let title: String
    let note: String
    let picture: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                TourPicture(name: picture, width: 384, portion: 0.53)   // ends in the gap between the Ask AI line (to 51.6 %) and the CPU widget (from 54 %)
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 24, weight: .bold))
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
                    }
                }
                Text(note).font(.system(size: 16)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(selected ? 0.09 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.16), lineWidth: selected ? 4 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .tourRect(id)
        .accessibilityLabel(Text(verbatim: "\(title). \(note)"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A big option: a name with a small sample, marked when it is the pick.
private struct TourChoice: View {
    let id: String
    let title: String
    let sample: CGFloat
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(verbatim: "Aa").font(.system(size: sample, weight: .semibold))
                Text(title).font(.system(size: 20, weight: .bold))
            }
            .foregroundStyle(selected ? Color.black.opacity(0.88) : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? Theme.accent : Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.16), lineWidth: selected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Color.black.opacity(0.85)).padding(8) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .tourRect(id)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Pages

private struct PageFrame<Art: View>: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @ViewBuilder var art: () -> Art

    var body: some View {
        VStack(spacing: 22) {
            art().frame(height: 220)
            VStack(spacing: 10) {
                Text(title).font(.system(size: 34, weight: .semibold))
                Text(text)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 600)
            }
        }
        .padding(.top, 56)
        .padding(.horizontal, 44)
    }
}

/// The heading of a picking page: a title and a line under it.
private struct PickHeading: View {
    let title: LocalizedStringKey
    let line: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 34, weight: .semibold))
            Text(line).font(.system(size: 18)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 50)
    }
}

private struct WelcomePage: View {
    var body: some View {
        PageFrame(title: "Welcome to Scout", text: "Let's make your notch look right. It takes under a minute.") {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 170, height: 170)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        }
    }
}

/// Page 2: the look, as two real pictures of the same dashboard.
private struct LookPage: View {
    @Binding var eightBit: Bool
    let preset: Look.Preset

    var body: some View {
        VStack(spacing: 22) {
            PickHeading(title: "Pick your look", line: "The same notch, drawn two ways. You can change it any time in Settings.")
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                TourCard(id: "look.8bit", title: String(localized: "8-bit"), note: String(localized: "The 90s look: pixel agents, chunky keys, LCD digits."),
                         picture: TourPictures.name(eightBit: true, preset: preset), selected: eightBit) { eightBit = true }
                TourCard(id: "look.minimal", title: String(localized: "Minimal"), note: String(localized: "Flat, plain and quiet: simple shapes and the system font."),
                         picture: TourPictures.name(eightBit: false, preset: preset), selected: !eightBit) { eightBit = false }
            }
            .padding(.horizontal, 40)
            Text("Click one, or use the arrow keys. Press Return to go on.").font(.system(size: 15)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

/// Page 3: the size: the island on a screen, as big as each choice makes it.
private struct SizePage: View {
    let size: Look.Size
    let eightBit: Bool
    let preset: Look.Preset
    let pick: (Look.Size) -> Void

    private let sampleSizes: [CGFloat] = [22, 27, 33]
    private static let baseIsland: CGFloat = 520
    /// The desktop is as tall as the biggest pick's island (the picture's own shape: 1016 x 180 pt) and a strip of desktop under it, so no
    /// pick leaves a wide empty band.
    private static let screenHeight: CGFloat = (baseIsland * (Look.Size.allCases.map(\.factor).max() ?? 1) * LookGallery.pictureHeight / LookGallery.pictureWidth).rounded(.up) + 40

    var body: some View {
        VStack(spacing: 20) {
            PickHeading(title: "Pick a size", line: "Everything in the open notch gets bigger, so it is easy to read.")
            HStack(spacing: 16) {
                ForEach(Array(Look.Size.allCases.enumerated()), id: \.element) { i, option in
                    TourChoice(id: "size.\(option.rawValue)", title: option.title, sample: sampleSizes[i], selected: size == option) { pick(option) }
                }
            }
            .padding(.horizontal, 44)
            screen
            Text("Click one, or use the arrow keys. The window grows with it.").font(.system(size: 15)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// A desktop with its menu bar and the open notch hanging from the top edge at the picked size.
    private var screen: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.75, blue: 0.98), Color(red: 0.98, green: 0.72, blue: 0.62)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack {
                HStack(spacing: 10) {   // a sample menu bar: the app's name, then the menus macOS shows in the person's language
                    Text(verbatim: "Scout")
                    Text("File")
                    Text("Edit")
                    Text("View")
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.black.opacity(0.65))
                Spacer()
                Text(verbatim: "10:41").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.black.opacity(0.65))
            }
            .padding(.horizontal, 14)
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.35))
            TourPicture(name: TourPictures.name(eightBit: eightBit, preset: preset), width: Self.baseIsland * size.factor)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                .tourRect("size.preview")
        }
        .frame(width: 780, height: Self.screenHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("A preview of the open notch at the size you picked")
    }
}

/// Page 4: the colours: dark or light, shown on the dashboard in the look just picked.
private struct ColourPage: View {
    let preset: Look.Preset
    let eightBit: Bool
    let pick: (Look.Preset) -> Void

    var body: some View {
        VStack(spacing: 22) {
            PickHeading(title: "Pick your colours", line: "Dark is the black notch. Light is warm paper with dark text. The closed notch always stays black.")
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                TourCard(id: "colour.dark", title: String(localized: "Dark"), note: String(localized: "Black, like the camera housing. Easy on the eyes at night."),
                         picture: TourPictures.name(eightBit: eightBit, preset: .dark), selected: preset == .dark) { pick(.dark) }
                TourCard(id: "colour.light", title: String(localized: "Light colourful"), note: String(localized: "Warm paper, dark text and bright accents. Easy to read by day."),
                         picture: TourPictures.name(eightBit: eightBit, preset: .light), selected: preset == .light) { pick(.light) }
            }
            .padding(.horizontal, 40)
            Text("Click one, or use the arrow keys. Press Return to go on.").font(.system(size: 15)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

private struct NotchPage: View {
    var body: some View {
        PageFrame(title: "The notch is alive",
                  text: "While music plays, a timer runs or a download finishes, the notch grows to show it. Point at it and it opens into your Nook: widgets, files, clipboard, calendar. Move away and it tucks back in.") {
            NotchArt()
        }
    }
}

private struct PermissionsPage: View {
    @AppStorage("media.spotify.control") private var spotify = false
    @AppStorage("media.music.control") private var music = false
    @AppStorage("bluetooth.monitor") private var bluetooth = false
    @State private var accessibility = Permissions.accessibilityGranted

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised.fill").font(.system(size: 40)).foregroundStyle(Theme.accent).padding(.top, 46)
            Text("Only what you choose").font(.system(size: 34, weight: .semibold))
            Text("Nothing is asked until you turn it on. Skip all of it if you like; every switch lives in Settings too.")
                .font(.system(size: 17)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            VStack(spacing: 0) {
                row("Spotify", "Covers, seeking and play/pause", $spotify, id: NowPlayingService.spotifyID)
                Divider()
                row("Apple Music", "Covers, seeking and play/pause", $music, id: NowPlayingService.musicID)
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility").font(.system(size: 16, weight: .medium))
                        Text(accessibilityDetail).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if accessibility {
                        StatusPill("Allowed", tone: .good)
                    } else {
                        Button("Allow…") { Permissions.requestAccessibility() }.controlSize(.regular)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bluetooth").font(.system(size: 16, weight: .medium))
                        Text(bluetoothDetail).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $bluetooth).labelsHidden().toggleStyle(.switch)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 580)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibility = Permissions.accessibilityGranted
        }
    }

    private var bluetoothDetail: String {
        #if APPSTORE
        String(localized: "Show AirPods and other devices when they connect")
        #else
        String(localized: "Show AirPods and their battery when they connect")
        #endif
    }

    private var accessibilityDetail: String {
        #if APPSTORE
        String(localized: "Paste for you")
        #else
        String(localized: "Paste for you and replace the volume pop-up")
        #endif
    }

    private func row(_ name: String, _ detail: LocalizedStringKey, _ isOn: Binding<Bool>, id: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(.system(size: 16, weight: .medium))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn.wrappedValue }, set: { new in
                isOn.wrappedValue = new
                if new { NowPlayingService.shared.requestAccess(for: id) }
            })).labelsHidden().toggleStyle(.switch)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct DonePage: View {
    var body: some View {
        PageFrame(title: "You're all set",
                  text: "Look for the little agent face in the menu bar to open Settings or the notch any time. Change the look, size or colours again in Settings > Appearance. Have fun scouting.") {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.18)).frame(width: 170, height: 170)
                AgentFaceMark(zoom: 4, color: Theme.accent)
            }
        }
    }
}

// MARK: - Illustrations (our own drawings)

private struct NotchArt: View {
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.75, blue: 0.98), Color(red: 0.98, green: 0.72, blue: 0.62)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 440, height: 220)
            Rectangle().fill(Color.white.opacity(0.35)).frame(width: 440, height: 20)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
            ZStack(alignment: .top) {
                NotchShape(topRadius: 8, bottomRadius: 22).fill(Color.black)
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "music.note").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                        Spacer()
                        Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 20).frame(height: 20)
                    HStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.1))
                                .overlay(Image(systemName: ["play.circle", "timer", "calendar"][i]).font(.system(size: 20)).foregroundStyle(Theme.accent.opacity(0.9)))
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 14)
                }
            }
            .frame(width: 340, height: 124)
        }
        .frame(width: 440, height: 220)
    }
}

struct CompassStar: Shape {
    var inner: CGFloat = 0.28

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<8 {
            let angle = Double(i) / 8 * 2 * .pi - .pi / 2
            let radius = i % 2 == 0 ? r : r * inner
            let point = CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }
}
