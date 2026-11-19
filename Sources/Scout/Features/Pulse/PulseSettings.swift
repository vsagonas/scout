import SwiftUI

struct PulseSettingsSection: View {
    @AppStorage(PulsePrefs.styleKey) private var styleRaw = PulseStyle.cards.rawValue
    @AppStorage(PulsePrefs.metricsKey) private var metricsRaw = PulsePrefs.raw(PulsePrefs.defaultMetrics)
    @ObservedObject private var sampler = PulseSampler.shared

    private var selected: Set<PulseMetric> {
        let m = metricsRaw.split(separator: ",").compactMap { PulseMetric(rawValue: String($0)) }
        return Set(m.isEmpty ? PulsePrefs.defaultMetrics : m)
    }

    var body: some View {
        Section {
            Picker("Style", selection: $styleRaw) {
                ForEach(PulseStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            ForEach(PulseMetric.allCases.filter { !sampler.unavailable.contains($0) }) { m in
                Toggle(isOn: Binding(
                    get: { selected.contains(m) },
                    set: { on in
                        var set = selected
                        if on { set.insert(m) } else if set.count > 1 { set.remove(m) }
                        metricsRaw = PulsePrefs.raw(PulseMetric.allCases.filter { set.contains($0) })
                    })) {
                    Label(m.title, systemImage: m.symbol)
                }
            }
        } header: {
            Text("Pulse")
        } footer: {
            SettingsNote("Pulse reads CPU, memory, GPU, disk, battery and network every 1.5 seconds, only while the widget is on screen. Cards show the first two metrics, Rings the first four. Clicking the widget opens Activity Monitor.")
        }
        .onAppear { sampler.probe() }
    }
}