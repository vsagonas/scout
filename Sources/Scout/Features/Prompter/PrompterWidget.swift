import SwiftUI

/// The Prompter panel on the dashboard: the selected script and Start. A click on the panel opens the whole Prompter (every
/// script, the mode and the speed).
struct PrompterWidgetView: View {
    @ObservedObject private var store: ScriptStore
    @AppStorage(PrompterPrefs.mode) private var modeRaw = PrompterController.Mode.steady.rawValue
    @Environment(\.notchNavigator) private var navigator

    @MainActor init(store: ScriptStore? = nil) { _store = ObservedObject(wrappedValue: store ?? ScriptStore.shared) }

    private var mode: PrompterController.Mode { PrompterController.Mode(rawValue: modeRaw) ?? .steady }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Dash90Title("Prompter", symbol: "text.viewfinder", tint: Retro.Ink.purple) {
                Dash90Text(mode.title, pixel: 1, color: Look.osd)
            }
            if let script = store.selected {
                (script.title.isEmpty ? Text("Untitled script") : Text(verbatim: script.title)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                (script.text.isEmpty ? Text("This script is empty.") : Text(verbatim: script.text))
                    .font(.system(size: 10.5)).foregroundStyle(NotchInk.secondary).lineLimit(2)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text("Words: \(script.wordCount)").font(.system(size: 10)).foregroundStyle(NotchInk.tertiary)
                    Spacer(minLength: 0)
                    Button { start(script) } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.retro(tint: Retro.Ink.purple, compact: true))
                        .disabled(script.text.isEmpty)
                        .nookControl()
                }
            } else {
                Spacer(minLength: 0)
                Text("No scripts yet").font(.system(size: 11, weight: .medium)).foregroundStyle(NotchInk.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchContent()
        .onAppear { store.load() }
    }

    private func start(_ script: PrompterScript) {
        navigator.forceClose()
        PrompterController.shared.start(script, mode: mode)
    }
}
