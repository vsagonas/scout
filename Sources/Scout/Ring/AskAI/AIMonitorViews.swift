import AppKit
import SwiftUI

// Monitor's face: the chip next to the input (a small display, lit amber when on) and the note under the input when a
// question had to go without its picture. Colours follow the surroundings, so the same views serve the floating panel
// (light or dark) and the notch (always dark).

/// A tiny desk monitor: a screen on a stand. Lit and glowing when Monitor is on, a quiet outline when off.
struct AIMonitorGlyph: View {
    var on: Bool

    var body: some View {
        VStack(spacing: 1.5) {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(on ? Theme.accent : Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(on ? Theme.accent : Color.primary.opacity(0.5), lineWidth: 1.2)
                if on {
                    // The light on the glass.
                    Capsule().fill(Color.white.opacity(0.55)).frame(width: 6, height: 1.6).offset(x: -3.5, y: -2.6)
                }
            }
            .frame(width: 17, height: 11.5)
            Capsule().fill(on ? Theme.accent : Color.primary.opacity(0.45)).frame(width: 7, height: 1.7)
        }
        .shadow(color: on ? Theme.accent.opacity(0.6) : .clear, radius: 3)
        .frame(width: 19, height: 16)
    }
}

private struct AIMonitorCompactKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when there is too little room for the word "Screen": the chip then keeps only its icon.
    var aiMonitorCompact: Bool {
        get { self[AIMonitorCompactKey.self] }
        set { self[AIMonitorCompactKey.self] = newValue }
    }
}

/// The on/off chip. One click toggles Monitor for the notch, the panel and Settings alike. With little room (the panel
/// says so through `aiMonitorCompact`, and a very tight container squeezes it too) it is just the icon; the tooltip and
/// the accessibility label stay.
struct AIMonitorChip: View {
    var isOn: Bool
    /// The provider the picture goes to, for the tooltip (nil: the one chosen in Settings).
    var provider: AIProvider?
    var action: () -> Void
    @Environment(\.aiMonitorCompact) private var compact
    @State private var hover = false
    /// A pill drawn as a rounded rectangle: a Capsule's outline grows little ticks at its ends when it is this small.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 11, style: .circular) }

    var body: some View {
        Button(action: action) {
            Group {
                if compact { face(showWord: false) } else { ViewThatFits(in: .horizontal) { face(showWord: true); face(showWord: false) } }
            }
            .background(shape.fill(isOn ? Theme.accent.opacity(0.2) : Color.primary.opacity(hover ? 0.12 : 0.08)))
            .overlay(shape.strokeBorder(isOn ? Theme.accent.opacity(0.85) : Color.clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(AIDisclosure.screenHelp(provider))
        .accessibilityLabel("Screen")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private func face(showWord: Bool) -> some View {
        HStack(spacing: 5) {
            AIMonitorGlyph(on: isOn)
            if showWord {
                Text("Screen").font(.system(size: 11, weight: .medium)).foregroundStyle(isOn ? Color.primary : Color.secondary)
            }
        }
        .padding(.leading, 7).padding(.trailing, showWord ? 9 : 7).padding(.vertical, 3)
    }
}

/// Under the input: the last question went without its picture, and where to fix it.
struct AIMonitorNoteView: View {
    var note: AIMonitorNote
    var onDismiss: () -> Void
    /// The notch closes after the button; the panel does nothing more.
    var afterSettings: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange).padding(.top, 1)
            Text(note.text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                Permissions.openSettings(.screenRecording)
                afterSettings()
            } label: {
                Text("Open Settings").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("System Settings › Privacy & Security › Screen Recording")
            Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 2).help("Dismiss")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.13)))
    }
}

/// In the question's bubble while its picture of the screen is being taken.
struct AIMonitorPending: View {
    var body: some View {
        HStack(spacing: 6) {
            AIWorkingRing(size: 11)
            Text("Taking a picture of your screen…").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// A picture of the screen in a message: wide, with a small display badge (the pictures people attach are squares).
struct AIScreenThumb: View {
    let file: String
    var width: CGFloat = 150

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: AIImages.url(file)) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.1)
            }
        }
        .frame(width: width, height: width * 0.62).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 3) {
                Image(systemName: "display").font(.system(size: 8, weight: .semibold))
                Text("Screen").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(5)
        }
    }
}
