import AppKit
import SwiftUI

// MARK: - The panel under the camera

struct PrompterPanelView: View {
    @ObservedObject var controller: PrompterController
    private var size: CGSize { PrompterController.panelSize }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        ZStack {
            shape.fill(Color.black.opacity(0.97))
            // The line being read.
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07))
                .frame(width: size.width - 56, height: controller.layout.fontSize * 1.42)
                .position(x: size.width / 2, y: PrompterController.readingLine)
            PrompterCanvas(controller: controller).clipShape(shape)
            fades
            readingMarks
            overlay
            if controller.notice == nil { bottomBar }
            noticeBanner
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var fades: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.black.opacity(0.92), .clear], startPoint: .top, endPoint: .bottom).frame(height: 30)
            Spacer()
            LinearGradient(colors: [.clear, Color.black.opacity(0.95)], startPoint: .top, endPoint: .bottom).frame(height: 26)
            Color.black.opacity(0.95).frame(height: 26)
        }
        .clipShape(shape).allowsHitTesting(false)
    }

    private var readingMarks: some View {
        HStack {
            Image(systemName: "arrowtriangle.right.fill")
            Spacer()
            Image(systemName: "arrowtriangle.left.fill")
        }
        .font(.system(size: 9)).foregroundStyle(Theme.accent)
        .padding(.horizontal, 12)
        .position(x: size.width / 2, y: PrompterController.readingLine)
        .frame(width: size.width)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var overlay: some View {
        switch controller.phase {
        case .countdown(let n):
            ZStack {
                shape.fill(Color.black.opacity(0.78))
                Text(verbatim: "\(n)").font(.system(size: 74, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent).monospacedDigit()
            }
        case .finished:
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
                Text("That's the end").font(.system(size: 14, weight: .semibold))
                Text("Return reads it again. Esc closes.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(16).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.85)))
        default:
            EmptyView()
        }
    }

    /// Why Voice mode changed how it follows (it goes away by itself). It sits low, under the line being read,
    /// so the reading never stops.
    @ViewBuilder private var noticeBanner: some View {
        if let notice = controller.notice, controller.phase != .finished {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(notice.text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(notice.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if notice.link != nil { Button("Settings") { notice.open() }.buttonStyle(.notchPillCompact) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.13)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .transition(.opacity)
        }
    }

    private var bottomBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                if controller.mode == .voice, controller.follow == .sound {
                    LevelDots(level: controller.level)
                    Text(controller.phase == .paused ? "Paused" : (controller.speaking ? "Following your voice · \(controller.wpm) wpm" : "Waiting for your voice"))
                        .lineLimit(1)
                } else if controller.mode == .voice {
                    LevelDots(level: controller.level)
                    (controller.phase == .paused ? Text("Paused") : (controller.heard.isEmpty || !Pref.bool(PrompterPrefs.showWords, true) ? Text("Listening…") : Text(verbatim: controller.heard)))
                        .lineLimit(1).truncationMode(.head)
                } else {
                    Image(systemName: controller.phase == .paused ? "pause.fill" : "forward.fill").font(.system(size: 9))
                    Text(controller.phase == .paused ? "Paused" : "\(controller.wpm) wpm")
                }
                Spacer(minLength: 6)
                Text("Space  ·  ↑↓ speed  ·  Esc").foregroundStyle(.white.opacity(0.4))
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 18).padding(.bottom, 8)
        }
        .allowsHitTesting(false)
    }
}

struct LevelDots: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(Float(i) / 4 < level ? Theme.accent : Color.white.opacity(0.25)).frame(width: 3, height: 3 + CGFloat(i) * 2)
            }
        }
        .frame(height: 10, alignment: .bottom)
    }
}

// MARK: - The workspace in the notch

struct PrompterWorkspaceView: View {
    @ObservedObject private var store = ScriptStore.shared
    @ObservedObject private var controller = PrompterController.shared
    @AppStorage(PrompterPrefs.mode) private var modeRaw = PrompterController.Mode.steady.rawValue
    @AppStorage(PrompterPrefs.wpm) private var wpm = 150

    private var mode: PrompterController.Mode { PrompterController.Mode(rawValue: modeRaw) ?? .steady }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            list.frame(width: 230)
            Rectangle().fill(NotchInk.hairline).frame(width: 1)
            detail
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchContent()
        .onAppear { store.load() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scripts").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { PrompterScriptsWindow.show() } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(.notchPillCompact)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(store.scripts) { script in
                        let selected = (store.selected?.id == script.id)
                        Button { store.selectedID = script.id } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text").foregroundStyle(selected ? Theme.accent : NotchInk.tertiary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(script.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text("Words: \(script.wordCount)").font(.system(size: 10)).foregroundStyle(NotchInk.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accent.opacity(0.22) : NotchInk.tile))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let script = store.selected {
                Text(script.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                (script.text.isEmpty ? Text("This script is empty. Press Edit to write it.") : Text(verbatim: script.text))
                    .font(.system(size: 12)).foregroundStyle(NotchInk.secondary).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Picker("", selection: $modeRaw) {
                    ForEach(PrompterController.Mode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                if mode == .steady {
                    Stepper(value: $wpm, in: 60...300, step: 10) { Text("\(wpm) wpm").font(.system(size: 11)).monospacedDigit() }
                        .controlSize(.small).fixedSize()
                } else {
                    Text("Follows your voice").font(.system(size: 11)).foregroundStyle(NotchInk.secondary)
                }
                Spacer()
                Button { startReading() } label: { Label("Start", systemImage: "play.fill") }.buttonStyle(NotchPillButtonStyle(prominent: true))
                    .disabled(store.selected?.text.isEmpty ?? true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func startReading() {
        guard let script = store.selected else { return }
        NotchNavigator.shared.forceClose()
        PrompterController.shared.start(script, mode: mode)
    }
}

// MARK: - Scripts window (list + editor)

@MainActor
enum PrompterScriptsWindow {
    static func show() {
        Panels.show(id: "prompter.scripts", options: Panels.Options(size: CGSize(width: 680, height: 460), minSize: CGSize(width: 520, height: 340), position: .center)) {
            PrompterScriptsView().background(GlassBackground(cornerRadius: 16))
        }
    }
}

struct PrompterScriptsView: View {
    @ObservedObject private var store = ScriptStore.shared
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Prompter scripts", symbol: "text.viewfinder", accessory: {
                Button { selection = store.add().id } label: { Label("New script", systemImage: "plus") }.controlSize(.small)
            })
            HStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.scripts) { s in
                        VStack(alignment: .leading, spacing: 1) {
                            (s.title.isEmpty ? Text("Untitled script") : Text(verbatim: s.title)).lineLimit(1)
                            Text("Words: \(s.wordCount)").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(s.id)
                    }
                }
                .frame(width: 190)
                Divider()
                if let id = selection ?? store.selected?.id, let index = store.scripts.firstIndex(where: { $0.id == id }) {
                    editor(index)
                } else {
                    Text("Choose a script").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { store.load(); selection = store.selected?.id }
        .onChange(of: selection) { if let selection { store.selectedID = selection } }
    }

    private func editor(_ index: Int) -> some View {
        let binding = Binding<PrompterScript>(get: { store.scripts[index] }, set: { store.update($0) })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Title", text: Binding(get: { binding.wrappedValue.title }, set: { var s = binding.wrappedValue; s.title = $0; binding.wrappedValue = s }))
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) { store.delete(binding.wrappedValue.id); selection = store.selected?.id } label: { Image(systemName: "trash") }
                    .help("Delete this script")
            }
            TextEditor(text: Binding(get: { binding.wrappedValue.text }, set: { var s = binding.wrappedValue; s.text = $0; binding.wrappedValue = s }))
                .font(.system(size: 14)).scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
            HStack {
                Text("Words: \(binding.wrappedValue.wordCount) · about \(max(1, binding.wrappedValue.wordCount / max(60, Pref.int(PrompterPrefs.wpm, 150)))) min at \(Pref.int(PrompterPrefs.wpm, 150)) wpm")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { PrompterController.shared.start(binding.wrappedValue, mode: PrompterController.Mode(rawValue: Pref.string(PrompterPrefs.mode, "steady")) ?? .steady) } label: {
                    Label("Read it", systemImage: "play.fill")
                }
                .disabled(binding.wrappedValue.text.isEmpty)
            }
        }
        .padding(12)
    }
}

// MARK: - Settings

struct PrompterSettingsPane: View {
    @AppStorage(PrompterPrefs.fontSize) private var fontSize = 28
    @AppStorage(PrompterPrefs.wpm) private var wpm = 150
    @AppStorage(PrompterPrefs.mirror) private var mirror = false
    @AppStorage(PrompterPrefs.language) private var language = ""
    @AppStorage(PrompterPrefs.showWords) private var showWords = true
    @AppStorage(PrompterPrefs.mode) private var mode = PrompterController.Mode.steady.rawValue

    private var languages: [(id: String, name: String)] {
        if ScoutRuntime.isScripted { return [("en-US", "English (United States)"), ("el-GR", "Greek (Greece)"), ("fr-FR", "French (France)")] }
        return SFSpeechRecognizerLocales.all
    }

    var body: some View {
        FeaturePane {
            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(PrompterController.Mode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Stepper("Text size: \(fontSize) pt", value: $fontSize, in: 18...48, step: 2)
                Stepper("Speed (Steady): \(wpm) wpm", value: $wpm, in: 60...300, step: 10)
                Toggle("Mirror the text (for a glass prompter)", isOn: $mirror)
                Button("Edit scripts…") { PrompterScriptsWindow.show() }
            } header: {
                Text("Reading")
            } footer: {
                SettingsNote("The Prompter sits right under the camera and is hidden from screen sharing and recordings. Steady scrolls at a set speed: ↑ and ↓ (or scrolling) change it, Space pauses, Esc closes.")
            }

            Section {
                Picker("Language", selection: $language) {
                    Text("Automatic (the script's language)").tag("")
                    ForEach(languages, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle("Show the words Scout hears", isOn: $showWords)
            } header: {
                Text("Voice")
            } footer: {
                SettingsNote("Voice mode listens on this Mac and keeps your place as you read. Nothing is sent anywhere. macOS asks for the Microphone and Speech Recognition the first time you use it. When the words can't be recognised (a language this Mac can't recognise offline, or Dictation turned off in System Settings › Keyboard), Scout follows the sound of your voice instead: the text moves while you speak and waits when you stop.")
            }
        }
    }
}
