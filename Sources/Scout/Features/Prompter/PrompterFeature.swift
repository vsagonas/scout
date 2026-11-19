import SwiftUI

@MainActor
enum PrompterFeature {
    static func start() {
        ScriptStore.shared.load()
        DebugCommands.register("prompter.open") { params in
            let mode = PrompterController.Mode(rawValue: params["mode"] ?? "steady") ?? .steady
            if let wpm = Int(params["wpm"] ?? "") { Pref.set(wpm, PrompterPrefs.wpm) }
            if let script = ScriptStore.shared.selected { PrompterController.shared.start(script, mode: mode) }
        }
        DebugCommands.register("prompter.close") { _ in PrompterController.shared.close() }
        DebugCommands.register("prompter.workspace") { _ in NotchNavigator.shared.open(.prompter) }
        DebugCommands.register("prompter.scripts") { _ in PrompterScriptsWindow.show() }
    }

    static func registerSelfTests() {
        FeaturesSelfTest.add("prompter: matcher follows reading, skips, noise and resyncs") {
            let text = "Welcome to Scout, the notch that does more. It reads your script while you talk. Skip a line and it finds you again. Thanks for listening."
            let m = ScriptMatcher(text: text)
            // Reading along (cumulative partial transcripts, the last word still changing).
            m.update(transcript: ["welcome", "to", "sco"], isFinal: false)
            guard m.cursor == 3 else { print("  cursor after 'welcome to sco' = \\(m.cursor)"); return false }
            m.update(transcript: ["welcome", "to", "scout", "the", "notch"], isFinal: false)
            guard m.cursor == 5 else { print("  cursor = \\(m.cursor)"); return false }
            // A misheard word is tolerated.
            m.update(transcript: ["welcome", "to", "scout", "the", "notch", "that", "dose", "more"], isFinal: false)
            guard m.cursor == 8 else { print("  cursor after 'dose more' = \\(m.cursor)"); return false }
            // Noise that is not in the script does not move the cursor.
            m.update(transcript: ["welcome", "to", "scout", "the", "notch", "that", "dose", "more", "banana"], isFinal: false)
            guard m.cursor == 8 else { print("  cursor after noise = \\(m.cursor)"); return false }
            // The reader skips ahead: the next request starts empty, words from further on are re-found.
            m.newRequest()
            m.update(transcript: ["skip", "a", "line", "and"], isFinal: false)
            guard m.cursor >= 18 else { print("  cursor after skip = \\(m.cursor)"); return false }
            // Skipping far ahead: three words from later in the script re-sync the cursor.
            let far = ScriptMatcher(text: text)
            far.update(transcript: ["welcome", "to"], isFinal: false)
            far.newRequest()
            far.update(transcript: ["thanks", "for", "listening"], isFinal: true)
            guard far.cursor == far.words.count else { print("  resync cursor = \(far.cursor) of \(far.words.count)"); return false }
            let words = ScriptText.words(in: "Hello — world, it's 5 o'clock!")
            return words.count == 6 && !words[1].speakable && words[2].norm == "world" && words[3].norm == "its"
        }
    }

    static func registerGallery() {
        let sample = ScriptStore.sample
        func panel(_ name: String, mode: PrompterController.Mode, phase: PrompterController.Phase, progress: Double, heard: String = "", level: Float = 0,
                   follow: PrompterController.Follow = .words, notice: PrompterController.Notice? = nil) {
            Gallery.register(name, size: CGSize(width: 580, height: 230), backdrop: .screenTop) {
                let c = PrompterController()
                PrompterPanelView(controller: c).onAppear {
                    c.previewState(script: sample, mode: mode, phase: phase, progress: progress, heard: heard, level: level, follow: follow, notice: notice)
                }
            }
        }
        panel("prompter-panel-steady", mode: .steady, phase: .playing, progress: 0.18)
        panel("prompter-panel-countdown", mode: .steady, phase: .countdown(2), progress: 0)
        panel("prompter-panel-voice", mode: .voice, phase: .playing, progress: 0.4, heard: "the words move at a steady pace and", level: 0.6)
        panel("prompter-panel-finished", mode: .steady, phase: .finished, progress: 1)
        // Voice mode when the words can't be recognised: it follows the sound of the voice, and says why once.
        panel("prompter-panel-sound", mode: .voice, phase: .playing, progress: 0.3, level: 0.55, follow: .sound)
        panel("prompter-panel-sound-notice", mode: .voice, phase: .playing, progress: 0.3, level: 0.55, follow: .sound,
              notice: .init(text: "Turn on Dictation to follow word by word",
                            detail: "Following the sound of your voice: it moves while you speak.", link: .keyboard))
        panel("prompter-panel-sound-waiting", mode: .voice, phase: .playing, progress: 0.3, level: 0, follow: .sound)
        FeatureGallery.workspace("prompter-workspace") { PrompterWorkspaceView() }
        Gallery.register("prompter-scripts", size: CGSize(width: 680, height: 460), backdrop: .wallpaper) {
            PrompterScriptsView().background(GlassBackground(cornerRadius: 16)).padding(10)
        }
        FeatureGallery.settings("settings-prompter", height: 760) { PrompterSettingsPane() }
    }
}
