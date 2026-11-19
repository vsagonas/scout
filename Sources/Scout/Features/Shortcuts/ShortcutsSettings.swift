import SwiftUI

struct ShortcutsSettingsSection: View {
    @ObservedObject private var service = ShortcutsService.shared
    @AppStorage(ShortcutsService.Key.favorites) private var favoritesRaw = ""
    @State private var newName = ""

    var body: some View {
        Section {
            #if APPSTORE
            ForEach(service.favorites, id: \.self) { name in
                HStack {
                    Image(systemName: "bolt.fill").foregroundStyle(Theme.accent)
                    Text(name)
                    Spacer()
                    Button { service.setFavorite(name, false) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Shortcut name", text: $newName, prompt: Text("Exactly as in the Shortcuts app")).onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || service.favorites.count >= ShortcutsService.maxFavorites)
            }
            HStack {
                Text("\(service.favorites.count) of \(ShortcutsService.maxFavorites) added").foregroundStyle(.secondary)
                Spacer()
                Button("Open Shortcuts") { service.openShortcutsApp() }
            }
            #else
            if !service.toolAvailable && !ScoutRuntime.isScripted {
                StatusRow(title: "Shortcuts", status: "Not available on this Mac", level: .bad)
            } else if service.all.isEmpty {
                StatusRow(title: "Your shortcuts", status: service.loaded ? "None found" : "Loading…", level: .neutral)
            } else {
                ForEach(service.all, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { service.isFavorite(name) },
                        set: { service.setFavorite(name, $0) }))
                        .disabled(!service.isFavorite(name) && service.favorites.count >= ShortcutsService.maxFavorites)
                }
            }
            HStack {
                Text("\(service.favorites.count) of \(ShortcutsService.maxFavorites) chosen").foregroundStyle(.secondary)
                Spacer()
                Button("Reload list") { service.reload() }
            }
            #endif
        } header: {
            Text("Shortcuts")
        } footer: {
            #if APPSTORE
            SettingsNote("Add up to eight shortcuts for the widget by typing their names. Clicking one opens the Shortcuts app and runs it. Scout can't see your shortcut list, so the names must match exactly.")
            #else
            SettingsNote("Pick up to eight shortcuts for the widget. Scout runs them with the system's shortcuts tool, only when you click.")
            #endif
        }
        .onAppear { if !service.loaded { service.reload() } }
    }

    #if APPSTORE
    private func add() {
        service.addFavorite(newName)
        newName = ""
    }
    #endif
}
