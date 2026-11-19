import SwiftUI

// Gallery scenes `led-*` for the announcement board: the whole font, sample messages in several tints, the closed notch with a
// welcome in the left wing (Step mode: start, middle, complete; one Scroll frame), a long message paging, and the settings rows.
// Synthetic project names only.

/// The closed notch as the gallery draws it: the real `NotchRootView` with the LED announcement in its wings.
struct LEDNotchScene: View {
    let size: CGSize
    @ObservedObject var model: NotchScreenModel
    @ObservedObject var center: LiveActivityCenter
    @ObservedObject var navigator: NotchNavigator
    @ObservedObject var nook: NookStore

    init(size: CGSize, playback: LEDPlayback, symbol: String?) {
        self.size = size
        let model = NotchScreenModel(geometry: .sample16, panelSize: size)
        let center = LiveActivityCenter()
        center.show(LEDAnnouncements.activity(playback, symbol: symbol, expiresAfter: 600))
        let nook = NookStore(persist: false, layout: [])
        self.model = model
        self.center = center
        self.navigator = NotchNavigator()
        self.nook = nook
    }

    var body: some View {
        ZStack(alignment: .top) {
            MockMenuBar(notch: .sample16)
            NotchRootView(model: model, center: center, navigator: navigator, nook: nook, styleOverride: .classic)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

@MainActor
enum LEDGallery {
    static let claude = AgentKind.claude.tint
    static let codex = AgentKind.codex.tint
    // The kit's palette (Core/Retro) for everything that is not an agent's own colour.
    static let amber = Retro.Ink.yellow
    static let blue = Retro.Ink.teal
    static let violet = Retro.Ink.purple
    static let red = Retro.Ink.red
    static let magenta = Retro.Ink.magenta

    /// A message as one wide board, whole (no paging), for judging the letters.
    private static func whole(_ text: String) -> LEDFrame {
        LEDFrame(columns: LEDFont.columns(text))
    }

    private static func playback(_ text: String, mode: LEDMode, tint: Color, at t: Double) -> LEDPlayback {
        var p = LEDPlayback(schedule: LEDSchedule(text: text, mode: mode), start: Date(), tint: tint, frozenAt: nil)
        p.frozenAt = t
        return p
    }

    private static func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.7))
    }

    static func register() {
        // The whole font.
        Gallery.register("led-font", size: CGSize(width: 640, height: 470), backdrop: .window) {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(["ABCDEFGHIJKLM", "NOPQRSTUVWXYZ", "0123456789", ".,:;!?-+/'\"()", "%&#@* \(LEDFont.heart)\(LEDFont.star)\(LEDFont.smile)\(LEDFont.arrow)\(LEDFont.check)\(LEDFont.note)\(LEDFont.creature)"], id: \.self) { line in
                    LEDBoardView(frame: whole(line), tint: amber, pitch: 7, plate: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        // Sample messages, large, in several tints.
        let samples: [(String, Color, String)] = [
            ("WELCOME NOTES \(LEDFont.heart)", claude, "Claude Code"),
            ("WELCOME API \(LEDFont.heart)", codex, "Codex"),
            ("BYE SITE", claude, "an agent leaves"),
            ("DOCS DONE \(LEDFont.check)", codex, "an agent finished"),
            ("HELLO FROM SCOUT \(LEDFont.heart)", amber, "the Test button"),
            ("NEW MAIL \(LEDFont.note) 3", blue, "blue"),
            ("LOW BATTERY 15%", red, "red"),
            ("\(LEDFont.creature) HI \(LEDFont.smile) \(LEDFont.star) \(LEDFont.arrow) OK?", violet, "violet, the cute glyphs"),
        ]
        Gallery.register("led-samples", size: CGSize(width: 760, height: CGFloat(samples.count) * 96 + 24), backdrop: .window) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(samples, id: \.0) { sample in
                    VStack(alignment: .leading, spacing: 4) {
                        caption(sample.2)
                        LEDBoardView(frame: whole(sample.0), tint: sample.1, pitch: 6, plate: true)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        // The closed notch, at its real size: Step mode start, middle, complete, and one Scroll frame.
        let step = LEDSchedule(text: "WELCOME NOTES \(LEDFont.heart)", mode: .step)
                let frames: [(String, LEDPlayback)] = [
            ("Step: the first columns light up", playback("WELCOME NOTES \(LEDFont.heart)", mode: .step, tint: claude, at: 0.30)),
            ("Step: half of the word is lit", playback("WELCOME NOTES \(LEDFont.heart)", mode: .step, tint: claude, at: 0.55)),
            ("Step: part 1 complete", playback("WELCOME NOTES \(LEDFont.heart)", mode: .step, tint: claude, at: 1.2)),
            ("Step: part 2 complete", playback("WELCOME NOTES \(LEDFont.heart)", mode: .step, tint: claude, at: step.pageStart(1) + 1.4)),
            ("Scroll: the marquee, 2.6 s in", playback("WELCOME NOTES \(LEDFont.heart)", mode: .scroll, tint: claude, at: 2.6)),
        ]
        let rowHeight: CGFloat = 78
        Gallery.register("led-notch", size: CGSize(width: 520, height: CGFloat(frames.count) * rowHeight + 8)) {
            VStack(spacing: 0) {
                ForEach(frames, id: \.0) { frame in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(frame.0).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).frame(height: 14)
                        LEDNotchScene(size: CGSize(width: 520, height: 58), playback: frame.1, symbol: AgentKind.claude.symbol)
                            .frame(width: 520, height: 58).clipped()
                        Color.clear.frame(height: 6)
                    }
                    .frame(width: 520, height: rowHeight, alignment: .top)
                }
            }
            .padding(.top, 8)
        }
        // The same frames, four times larger (the left wing only), to see the dots.
        let zoom: CGFloat = 4
        Gallery.register("led-notch-zoom", size: CGSize(width: 760, height: CGFloat(frames.count) * 150 + 8)) {
            VStack(spacing: 6) {
                ForEach(frames, id: \.0) { frame in
                    ZStack(alignment: .topLeading) {
                        Color.black
                        LEDNotchScene(size: CGSize(width: 520, height: 58), playback: frame.1, symbol: AgentKind.claude.symbol)
                            .frame(width: 520, height: 58)
                            .scaleEffect(zoom, anchor: .topLeading)
                            .offset(x: -zoom * 30, y: -zoom * 4)
                    }
                    .frame(width: 760, height: 144)
                    .clipped()
                }
            }
            .padding(.top, 8)
        }

        // The framed sign at its real size on the black notch, and three times as big, in the kit's palette (an agent's own colour for agents).
        let signs: [(String, Color)] = [
            ("WELCOME", claude), ("DONE \(LEDFont.check)", codex), ("INBOX 3", blue), ("LOW 15%", red), ("HELLO \(LEDFont.heart)", amber), ("HI \(LEDFont.smile)", magenta), ("OK?", violet),
        ]
        Gallery.register("led-sign", size: CGSize(width: 580, height: CGFloat(signs.count) * 84 + 24)) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(signs, id: \.0) { sign in
                    let schedule = LEDSchedule(text: sign.0, mode: .step)
                    let shown = playback(sign.0, mode: .step, tint: sign.1, at: schedule.lightDuration(page: 0) + 0.3)
                    HStack(spacing: 24) {
                        LEDWingLeft(playback: shown).frame(width: 130, alignment: .leading).padding(.leading, 10)
                        LEDWingLeft(playback: shown).scaleEffect(3, anchor: .leading).frame(width: 380, height: 76, alignment: .leading)
                    }
                    .frame(width: 556, height: 76, alignment: .leading)
                    .background(Color.black)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        // A long message paging in Step mode.
        let long = LEDSchedule(text: "WELCOME SCOUT-DASHBOARD \(LEDFont.heart)", mode: .step)
        Gallery.register("led-paging", size: CGSize(width: 640, height: CGFloat(long.pages.count) * 92 + 70), backdrop: .window) {
            VStack(alignment: .leading, spacing: 16) {
                caption("WELCOME SCOUT-DASHBOARD \(LEDFont.heart): \(long.pages.count) parts, \(String(format: "%.1f", long.duration)) s")
                ForEach(0..<long.pages.count, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 3) {
                        caption("part \(i + 1) of \(long.pages.count)")
                        LEDBoardView(frame: long.frame(at: long.pageStart(i) + long.lightDuration(page: i) + 0.1), tint: codex, pitch: 6, plate: true)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        // The settings rows (the Announcements switch in the list, the marquee switch and the Test button).
        Gallery.register("led-settings", size: CGSize(width: 640, height: 1310), backdrop: .window) {
            ScrollView {
                Registry.settingsView(.liveActivities).padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
