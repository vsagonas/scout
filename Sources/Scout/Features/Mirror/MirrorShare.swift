import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Share key of the Mirror tab. One click takes one still of the live picture (only while the camera is already on and showing), makes
// the polaroid of it with the agents (`MirrorPolaroid`) and shows it first in a small window:
// Share… opens the
// system share sheet from its key (the picture and one line of words; the sheet also lists "Save…"), Copy puts it on the clipboard, Save…
// asks where and writes a PNG (the sandbox allows the file the person picks, nothing else). Nothing is taken, kept or sent without those
// clicks, and Scout itself sends nothing anywhere.

@MainActor
final class MirrorShare: NSObject, @preconcurrency NSSharingServicePickerDelegate {
    static let shared = MirrorShare()

    /// What happens with the finished polaroid; tests put their own here (so no share sheet ever opens in a headless run).
    static var deliver: (NSImage, NSView?) -> Void = { image, _ in MirrorSharePreview.shared.show(image) }
    /// The agents that stand on the picture; tests put theirs here too.
    static var agentsProvider: () -> [PolaroidAgent] = { MirrorPolaroid.agents(sessions: AgentsStore.shared.sessions) }

    private var picker: NSSharingServicePicker?
    private var image: NSImage?
    private var busy = false
    private var holdToken = 0
    private var holdsNotch = false
    /// Runs once a service was picked in the sheet (the preview window closes then).
    private var onChosen: (() -> Void)?
    /// The "Save…" entry added to the share sheet (found again by identity, never by its title: the title is in the person's language).
    private var saveService: NSSharingService?

    // MARK: The click

    /// Takes the still of the picture on screen now and delivers its polaroid. Does nothing while a polaroid is on its way.
    static func start(model: MirrorModel, tools: MirrorTools, flip: Bool, anchor: NSView?) {
        guard !shared.busy else { return }
        shared.busy = true
        Task { @MainActor in
            defer { shared.busy = false }
            guard let still = await MirrorCamera.still(model: model, tools: tools, flip: flip) else {
                Toast.show("Turn on the camera first", symbol: "camera", style: .info)
                return
            }
            guard let polaroid = MirrorPolaroid.image(photo: still, agents: agentsProvider()) else {
                Toast.show("Couldn't make the polaroid", symbol: "exclamationmark.triangle.fill", style: .error)
                return
            }
            deliver(polaroid, anchor)
        }
    }

    // MARK: The share sheet

    /// The share sheet from `anchor` (a key): the polaroid and the words. Never in a scripted run. From a key on the island, the island is
    /// held open while the sheet is up; from the preview window, nothing is held and `onChosen` runs once a service was picked.
    func present(_ polaroid: NSImage, from anchor: NSView?, holdNotch: Bool = true, onChosen: (() -> Void)? = nil) {
        guard !ScoutRuntime.isScripted, let anchor, anchor.window != nil else { return }
        let picker = NSSharingServicePicker(items: [polaroid, MirrorPolaroid.shareText])
        picker.delegate = self
        self.picker = picker
        image = polaroid
        self.onChosen = onChosen
        holdsNotch = holdNotch
        if holdNotch { NotchNavigator.shared.hold(Self.holdReason) }
        holdToken += 1
        let token = holdToken
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // If the sheet never reports that it is gone, the island is let go after a while.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.holdToken == token else { return }
            self.releaseHold()
        }
    }

    private static let holdReason = "mirror.share"

    private func releaseHold() {
        holdToken += 1
        if holdsNotch { NotchNavigator.shared.release(Self.holdReason) }
        holdsNotch = false
        picker = nil
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                              proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        var list = proposedServices
        if let polaroid = image {
            let icon = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: String(localized: "Save")) ?? NSImage()
            let save = NSSharingService(title: String(localized: "Save…"), image: icon, alternateImage: nil) {
                // After the sheet is gone: the save panel asks where (on the preview window when it shows).
                DispatchQueue.main.async { MirrorShare.save(polaroid, on: MirrorSharePreview.shared.currentWindow) }
            }
            saveService = save
            list.append(save)
        }
        return list
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let chosen = onChosen
        onChosen = nil
        releaseHold()
        // Save… keeps the window for its sheet; any other service closes the preview once it has the picture.
        if let service, service !== saveService { chosen?() }
    }

    // MARK: Save…

    /// Asks where to save, then writes the polaroid as a PNG there. Only after a click on Save…; nothing is written anywhere else. On a window
    /// (the preview), the save panel hangs from it as a sheet, so it is never hidden behind it.
    static func save(_ polaroid: NSImage, on window: NSWindow? = nil) {
        guard !ScoutRuntime.isScripted else { return }
        guard let data = MirrorPolaroid.pngData(polaroid) else {
            Toast.show("Couldn't save the polaroid", symbol: "exclamationmark.triangle.fill", style: .error)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = MirrorPolaroid.fileName()
        panel.canCreateDirectories = true
        func write(_ url: URL) {
            do {
                try data.write(to: url)
                Toast.show("Saved \(url.lastPathComponent)", symbol: "square.and.arrow.down")
            } catch {
                Toast.show("Couldn't save the polaroid", symbol: "exclamationmark.triangle.fill", style: .error)
            }
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                write(url)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(url)
    }

    /// Copy in the preview: the polaroid on the clipboard as a picture (the clipboard history keeps it too).
    @discardableResult
    static func copy(_ polaroid: NSImage) -> Bool {
        guard let cg = polaroid.cgImage(forProposedRect: nil, context: nil, hints: nil), MirrorSnap.copy(cg) else {
            Toast.show("Couldn't copy the polaroid", symbol: "exclamationmark.triangle.fill", style: .error)
            return false
        }
        Toast.show("Copied the polaroid", symbol: "doc.on.doc")
        return true
    }
}

// MARK: - The key

/// A groove between two groups of keys in the Mirror's toolbar (a hairline in the minimal look).
struct MirrorToolbarDivider: View {
    var body: some View {
        if !Retro.is8bit {
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 0.5, height: 16)
        } else {
            HStack(spacing: 0) {
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: 1, height: 18)
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 18)
            }
        }
    }
}

/// The Share key and the groove before it: a chunky retro key in the 8-bit look, a plain icon button in the minimal one (`DeckKey` draws
/// both). A gallery picture (`enabled` false) draws it and never acts.
struct MirrorShareKey: View {
    var model: MirrorModel
    var tools: MirrorTools
    var flip: Bool
    var enabled = true
    @State private var anchor = MirrorShareAnchor.Box()

    var body: some View {
        HStack(spacing: 6) {
            MirrorToolbarDivider()
            MirrorToolButton(symbol: "square.and.arrow.up", help: "Share a polaroid of me and my agents") {
                guard enabled else { return }
                MirrorShare.start(model: model, tools: tools, flip: flip, anchor: anchor.view)
            }
            .background(MirrorShareAnchor(box: anchor))
            .mirrorRect("share")
        }
    }
}

/// Finds the key's own view, the place the share sheet hangs from.
struct MirrorShareAnchor: NSViewRepresentable {
    final class Box {
        weak var view: NSView?
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}
