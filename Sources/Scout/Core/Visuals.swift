import AppKit
import SwiftUI

// MARK: - Theme

enum Theme {
    /// Scout's signature amber. Users can pick their own accent in Settings › General ("app.accentHex").
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.13)

    static var accent: Color {
        if let hex = UserDefaults.standard.string(forKey: "app.accentHex"), let c = Color(hex: hex) { return c }
        return amber
    }

    static let cornerLarge: CGFloat = 22
    static let cornerMedium: CGFloat = 14
    static let cornerSmall: CGFloat = 8

    /// The standard motion. With Reduce Motion ON it becomes a short fade-friendly ease.
    static var spring: Animation {
        ScoutRuntime.reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.36, dampingFraction: 0.82)
    }

    static var quick: Animation {
        ScoutRuntime.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.86)
    }
}

extension Color {
    /// "#RRGGBB" or "RRGGBB" (optionally "AA" at the end).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(round(ns.redComponent * 255)), Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }
}

// MARK: - Materials

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        update(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { update(view) }

    private func update(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blending
        view.isEmphasized = emphasized
    }
}

/// Glass on macOS 26+, a vibrant material before that, a flat fill in gallery renders
/// (offscreen captures can't draw blur, so gallery PNGs show the shape and colors only).
struct GlassBackground<S: Shape>: View {
    var shape: S
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    init(_ shape: S, tint: Color? = nil) {
        self.shape = shape
        self.tint = tint
    }

    var body: some View {
        if ScoutRuntime.isGallery {
            shape.fill(scheme == .dark ? Color(white: 0.14, opacity: 0.94) : Color(white: 0.97, opacity: 0.94))
                .overlay(shape.fill((tint ?? .clear).opacity(0.18)))
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? .regular, in: shape)
        } else {
            VisualEffectBackground(material: .hudWindow)
                .overlay((tint ?? .clear).opacity(0.18))
                .clipShape(shape)
        }
    }
}

extension GlassBackground where S == RoundedRectangle {
    init(cornerRadius: CGFloat = Theme.cornerMedium, tint: Color? = nil) {
        self.init(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
    }
}

// MARK: - Placeholders (stubs show this until someone builds the real view)

struct PlaceholderView: View {
    let title: String
    var lane: Lane = .lead

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "hammer").font(.system(size: 18)).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("Not built yet").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary.opacity(0.6))
        )
        .padding(6)
    }
}

// MARK: - Haptics

enum Haptics {
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "app.haptics") as? Bool ?? true }

    /// A light tick (pointer crosses into a ring slice, notch changes state).
    static func tick() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// A firmer step (slider detents, timer wheel).
    static func step() {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
