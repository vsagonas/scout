import SwiftUI

@MainActor
enum PulseFeature {
    static func start() {}

    static func registerSelfTests() {
        FeaturesSelfTest.add("pulse: real readings are sane") {
            let sampler = PulseSampler()
            sampler.sampleNow()
            Thread.sleep(forTimeInterval: 1.0)
            // Burn a little CPU so the delta is not zero.
            var x = 0.0
            for i in 0..<3_000_000 { x += sin(Double(i)) }
            sampler.sampleNow()
            let s = sampler.latest
            print("  pulse: cpu \(Int(s.cpu * 100))% mem \(Int(s.memory * 100))% (\(FeatureFormat.bytes(s.memoryUsedBytes))) gpu \(s.gpu.map { "\(Int($0 * 100))%" } ?? "n/a") disk \(Int(s.disk * 100))% battery \(s.battery.map { "\(Int($0 * 100))%" } ?? "n/a") down \(Int(s.netDown)) B/s up \(Int(s.netUp)) B/s \(x > 1e9 ? "" : "")")
            return (0...1).contains(s.cpu) && s.memory > 0.05 && s.memory <= 1 && s.disk > 0 && s.disk <= 1
        }
    }

    static func registerGallery() {
        let all: [PulseMetric] = [.cpu, .memory, .gpu, .network, .disk, .battery]
        FeatureGallery.widget("pulse-widget-cards", span: 4) { PulseWidgetView(style: .cards, metrics: [.cpu, .memory]) }
        FeatureGallery.widget("pulse-widget-cards-net", span: 4) { PulseWidgetView(style: .cards, metrics: [.gpu, .network]) }
        FeatureGallery.widget("pulse-widget-rings", span: 4) { PulseWidgetView(style: .rings, metrics: all) }
        FeatureGallery.widget("pulse-widget-list", span: 4) { PulseWidgetView(style: .list, metrics: all) }
        FeatureGallery.settings("settings-widgets", height: 700) { WidgetsSettingsPane() }
    }
}
