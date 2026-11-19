import AppKit
import SwiftUI

@MainActor
enum UnitsPanel {
    static func show() {
        CurrencyRates.shared.refreshIfNeeded()
        let m = ToolMemory.load(UnitsMemory.self, ToolMemory.unitsState)
        ToolPanels.show("units", size: CGSize(width: 380, height: 400), minSize: CGSize(width: 340, height: 360), resizable: true) {
            if let m {
                UnitsView(quick: m.quick, category: UnitCategory(rawValue: m.category) ?? .length, amount: m.amount, from: m.from, to: m.to)
            } else {
                UnitsView()
            }
        }
    }
}

/// What was in the Units panel when it closed.
struct UnitsMemory: Codable, Equatable {
    var quick: String
    var category: String
    var amount: String
    var from: String
    var to: String
}

struct UnitsView: View {
    @ObservedObject private var rates = CurrencyRates.shared
    @State private var quick: String
    @State private var category: UnitCategory
    @State private var amount: String
    @State private var fromID: String
    @State private var toID: String
    @FocusState private var quickFocused: Bool

    init(quick: String = "", category: UnitCategory = .length, amount: String = "1", from: String? = nil, to: String? = nil) {
        _quick = State(initialValue: quick)
        _category = State(initialValue: category)
        _amount = State(initialValue: amount)
        let defaults = Self.defaultPair(category)
        _fromID = State(initialValue: from ?? defaults.0)
        _toID = State(initialValue: to ?? defaults.1)
    }

    static func defaultPair(_ c: UnitCategory) -> (String, String) {
        switch c {
        case .length: ("km", "mi")
        case .weight: ("kg", "lb")
        case .temperature: ("c", "f")
        case .volume: ("l", "gal")
        case .speed: ("km/h", "mph")
        case .area: ("m2", "ft2")
        case .data: ("gb", "mb")
        case .time: ("h", "min")
        case .currency: ("USD", "EUR")
        }
    }

    private var quickResult: String? {
        guard let p = UnitCatalog.parse(quick) else { return nil }
        let out = UnitCatalog.convert(p.value, from: p.from, to: p.to)
        return "\(UnitCatalog.format(p.value)) \(p.from.symbol) = \(UnitCatalog.format(out)) \(p.to.symbol)"
    }

    private var memory: UnitsMemory { UnitsMemory(quick: quick, category: category.rawValue, amount: amount, from: fromID, to: toID) }

    private var units: [UnitDef] { UnitCatalog.units(in: category) }
    private var from: UnitDef? { units.first { $0.id == fromID } ?? units.first }
    private var to: UnitDef? { units.first { $0.id == toID } ?? units.dropFirst().first ?? units.first }

    private var manualResult: String? {
        guard let from, let to, let v = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return UnitCatalog.format(UnitCatalog.convert(v, from: from, to: to))
    }

    var body: some View {
        ToolPanelFrame("Units", symbol: "ruler") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ToolSearchField(prompt: String(localized: "Try “5 km to mi” or “100 usd to eur”"), text: $quick, focus: $quickFocused)
                    if let quickResult {
                        Text(quickResult).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 4).onTapGesture { copy(quickResult) }
                    } else if !quick.isEmpty {
                        Text("Write it like “5 km to mi”.").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 4)
                    }
                }
                categoryChips
                converter
                Spacer(minLength: 0)
                if category == .currency { currencyFooter }
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
        }
        .onAppear { quickFocused = true }
        .onChange(of: category) { _, new in
            let d = Self.defaultPair(new)
            fromID = d.0
            toID = d.1
        }
        .onChange(of: memory) { _, new in ToolMemory.save(new, ToolMemory.unitsState) }
    }

    private var categoryChips: some View {
        let columns = [GridItem(.adaptive(minimum: 78), spacing: 6)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(UnitCategory.allCases) { c in
                Button { category = c } label: {
                    HStack(spacing: 4) {
                        Image(systemName: c.symbol).font(.system(size: 10))
                        Text(c.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity)
                    .background(Capsule().fill(category == c ? Theme.accent.opacity(0.28) : Color.primary.opacity(0.07)))
                    .foregroundStyle(category == c ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var converter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Amount", text: $amount).textFieldStyle(.roundedBorder).frame(width: 110).font(.system(size: 15, design: .rounded)).monospacedDigit()
                unitPicker($fromID)
            }
            HStack {
                Spacer()
                Button {
                    swap(&fromID, &toID)
                } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(.bordered).controlSize(.small).help("Swap")
                Spacer()
            }
            HStack(spacing: 8) {
                Text(manualResult ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.accent)
                    .lineLimit(1).minimumScaleFactor(0.5).frame(width: 150, alignment: .leading)
                    .onTapGesture { if let manualResult { copy(manualResult) } }
                    .help("Click to copy")
                unitPicker($toID)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func unitPicker(_ selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(units) { u in Text(verbatim: category == .currency ? "\(u.symbol) — \(u.displayName)" : "\(u.displayName) (\(u.symbol))").tag(u.id) }
        }
        .labelsHidden().frame(maxWidth: .infinity)
    }

    /// When the rates were last fetched ("from cache" while offline), or that they are not loaded.
    private var ratesLine: String {
        guard let updated = rates.updated else { return String(localized: "Rates not loaded yet") }
        let ago = ToolFormat.ago(updated)
        return rates.isOffline ? String(localized: "Rates from cache, updated \(ago)") : String(localized: "Rates updated \(ago)")
    }

    private var currencyFooter: some View {
        HStack(spacing: 5) {
            Image(systemName: rates.isOffline ? "wifi.slash" : "arrow.triangle.2.circlepath").font(.system(size: 10))
            Text(verbatim: ratesLine)
        }
        .font(.system(size: 10.5)).foregroundStyle(.secondary)
    }

    private func copy(_ text: String) {
        let plain = text.components(separatedBy: " = ").last ?? text
        if !ScoutRuntime.isScripted {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plain, forType: .string)
        }
        Toast.show("Copied \(plain)", symbol: "ruler")
    }
}
