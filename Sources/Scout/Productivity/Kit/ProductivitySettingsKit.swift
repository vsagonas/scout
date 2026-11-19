import AppKit
import Carbon.HIToolbox
import SwiftUI

// The productivity part's settings-page building blocks (own names, so they never clash with other parts' helpers).
// The settings window puts each page in a ScrollView with padding; pages are plain stacks of sections.

struct BPage<Content: View>: View {
    var intro: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let intro {
                Text(intro).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BSection<Content: View>: View {
    var title: LocalizedStringKey?
    var footer: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.leading, 4)
            }
            VStack(spacing: 0) { content() }
                .padding(.bottom, -1)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct BRow<Control: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider().padding(.leading, 12)
        }
    }
}

extension BRow where Control == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

/// A switch row bound to an @AppStorage-style Bool.
struct BToggleRow: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Binding var isOn: Bool

    var body: some View {
        BRow(title: title, subtitle: subtitle) { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch) }
    }
}

/// A button-styled link-like row action (aligned left, inside a section).
struct BActionRow: View {
    var title: LocalizedStringKey
    var symbol: String?
    var role: ButtonRole?
    var action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(role: role, action: action) {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol) }
                    Text(title)
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(role == .destructive ? Color.red : Theme.accent)
            Divider().padding(.leading, 12)
        }
    }
}

/// A shortcut stored as `KeyCombo.stringValue` under a UserDefaults key ("" = none).
struct ComboStorageBinding {
    static func binding(_ key: String, default fallback: KeyCombo?) -> Binding<KeyCombo?> {
        Binding(get: {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return fallback }
            return raw.isEmpty ? nil : KeyCombo(string: raw)
        }, set: { new in
            UserDefaults.standard.set(new?.stringValue ?? "", forKey: key)
        })
    }
}

extension KeyCombo {
    /// ⇧⌘V
    static let shiftCommandV = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: [.shift, .command])
}

/// A number with − / + buttons.
struct BStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step = 1
    var unit = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(value)\(unit.isEmpty ? "" : " \(unit)")").font(.system(size: 13)).monospacedDigit().frame(minWidth: 48, alignment: .trailing)
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
    }
}

/// Hex-string-backed color picker (settings keep colors as "#RRGGBB").
struct BHexColorWell: View {
    @Binding var hex: String

    var body: some View {
        ColorPicker("", selection: Binding(get: { Color(hex: hex) ?? Theme.accent }, set: { hex = $0.hexString }), supportsOpacity: false).labelsHidden()
    }
}
