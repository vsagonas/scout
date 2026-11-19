import SwiftUI

/// Settings › Appearance, right under General: every look in one place.
/// The 8-bit switch first (with both looks alive under it), the ONE System/Light/Dark setting for windows and notch, the accent colour;
/// then the notch (style, size, lines between panels). (The ring's section went with the ring, 2026-11-16.)
/// What a thing does stays on its own page (the opening tick, the ring's numbers and haptics).
struct AppearanceSettingsPane: View {
    @AppStorage(Retro.styleKey) private var retro8bit = true
    @AppStorage("app.appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("app.accentHex") private var accentHex = ""

    static let swatches: [(String, String)] = [
        (String(localized: "Amber"), "#FFB021"), (String(localized: "Orange"), "#FF7A33"), (String(localized: "Red"), "#F0544F"), (String(localized: "Pink"), "#EC5C9E"), (String(localized: "Purple"), "#9B6BF2"),
        (String(localized: "Blue"), "#3E8BFF"), (String(localized: "Teal"), "#2BB8B0"), (String(localized: "Green"), "#3FBF6A"), (String(localized: "Graphite"), "#8E939C"),
    ]

    var body: some View {
        Form {
            // The 8-bit switch first, with both looks alive under it
            Section {
                Toggle("8-bit style", isOn: $retro8bit).toggleStyle(.switch)
                AppearanceStylePreview(eightBit: retro8bit)
                // ONE light/dark setting for Scout's windows and the open notch together.
                Picker("Appearance", selection: Binding(get: { appearance }, set: { AppAppearance.set(AppAppearance(rawValue: $0) ?? .system) })) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent color") {
                    HStack(spacing: 7) {
                        ForEach(Self.swatches, id: \.1) { name, hex in
                            Button { accentHex = hex } label: {
                                Circle().fill(Color(hex: hex) ?? .gray).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(isCurrent(hex) ? 0.9 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(name)
                        }
                        ColorPicker("", selection: Binding(get: { Theme.accent }, set: { accentHex = $0.hexString }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            } header: {
                Text("Style")
            } footer: {
                SettingsFootnote("8-bit style is the 90s look: pixel agents in their den, chunky keys, LCD digits and a CRT screen. Switched off, everything is minimal and plain: flat shapes, the system font, simple lists and bars. Appearance is one setting for Scout's windows and the open notch: Light is a warm paper-coloured notch with dark text, Dark the black one, System follows your Mac. The closed notch stays black. The accent colour lights keys, highlights and progress.")
            }

            NotchLookSection()

        }
        .formStyle(.grouped)
    }

    private func isCurrent(_ hex: String) -> Bool {
        (accentHex.isEmpty ? "#FFB021" : accentHex).uppercased() == hex.uppercased()
    }
}

/// Both looks, alive, under the 8-bit switch: pixel agents hopping on a CRT with a blinking cursor while it is on, a plain card with a
/// breathing dot and bar while it is off. Switching crossfades from one to the other. It only runs while the page is on screen.
struct AppearanceStylePreview: View {
    let eightBit: Bool

    var body: some View {
        ZStack {
            if eightBit {
                AppearanceEightBitPreview().transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                AppearanceMinimalPreview().transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.35), value: eightBit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(eightBit ? "8-bit style preview" : "Minimal style preview")
    }
}

/// Three pixel agents taking turns to hop, "8-BIT READY" in phosphor green with a blinking cursor, on a little CRT.
struct AppearanceEightBitPreview: View {
    /// Pictures and tests: one still moment.
    var frozenAt: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: frozenAt != nil)) { ctx in
            let t = frozenAt ?? ctx.date.timeIntervalSinceReferenceDate
            let step = Int((t * 4).rounded(.down))
            HStack(spacing: 22) {
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { i in
                        AgentFaceIcon(agent: .claude, mood: .working, phase: Double(i) * 0.37, frozenAt: frozenAt, variant: [5, 77, 140][i], px: 2.5)
                            .offset(y: (step + i) % 3 == 0 ? -4 : 0)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    RetroPixelText("8-BIT", pixel: 3, color: Retro.Ink.phosphorGreen)
                    HStack(spacing: 3) {
                        RetroPixelText(pixelLabel("READY"), pixel: 1.5, color: Retro.Ink.phosphorGreen.opacity(0.8))
                        Rectangle().fill(Retro.Ink.phosphorGreen).frame(width: 6, height: 10).opacity(step % 4 < 2 ? 1 : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .crtScreen(cornerRadius: 12, scanlines: 0.10, tint: nil, vignette: 0.3)
        }
    }
}

/// A plain card: a dot breathing in its halo, a bar easing back and forth, three dots fading in turn. The system font, nothing pixelated.
struct AppearanceMinimalPreview: View {
    var frozenAt: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: frozenAt != nil)) { ctx in
            let t = frozenAt ?? ctx.date.timeIntervalSinceReferenceDate
            let wave = (sin(t * 1.6) + 1) / 2
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.18)).frame(width: 40 + 10 * wave, height: 40 + 10 * wave)
                    Circle().fill(Theme.accent).frame(width: 14, height: 14)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Minimal").font(.system(size: 15, weight: .semibold))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(Theme.accent).frame(width: 30 + 130 * wave)
                    }
                    .frame(width: 160, height: 5)
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().fill(Color.primary.opacity(0.2 + 0.5 * max(0, sin(t * 3 - Double(i) * 0.8)))).frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}
