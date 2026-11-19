import ImageIO
import PDFKit
import SwiftUI

@MainActor
enum TrayFeature {
    static func start() {
        TrayStore.shared.start()
        if ScoutRuntime.isScripted { /* sample items only on demand (tray.demo) */ }
        DebugCommands.register("tray.demo") { _ in
            TraySamples.fill(TrayStore.shared)
            NotchNavigator.shared.open(.tray)
        }
        DebugCommands.register("tray.clear") { _ in TrayStore.shared.clear() }
        DebugCommands.register("tray.open") { _ in NotchNavigator.shared.open(.tray) }
        DebugCommands.register("tray.droptargets") { params in
            NotchNavigator.shared.open()
            NotchNavigator.shared.isDropTargeting = (params["on"] ?? "1") != "0"
        }
        // scout://tray.convert?to=png converts the first sample image (scripted runs only touch Scout-Automation).
        DebugCommands.register("tray.convert") { params in
            let store = TrayStore.shared
            TraySamples.fill(store)
            let to = params["to"] ?? "png"
            guard let format = Converter.formats(for: store.targetURLs()).first(where: { $0.id == to })
                    ?? [ConvertFormat.png, .jpeg, .heic, .tiff, .pdf, .zip].first(where: { $0.id == to }) else { return }
            let sources = store.items.compactMap { store.url(for: $0) }.filter { to == "zip" || $0.isImageFile }
            store.convert(Array(sources.prefix(to == "zip" || to == "pdf" ? 2 : 1)), to: format)
        }
    }

    static func registerSelfTests() {
        let work = AppPaths.folder("SelfTest")
        func clean() { try? FileManager.default.removeItem(at: work); try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
        func pixelSize(_ url: URL) -> CGSize? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return CGSize(width: img.width, height: img.height)
        }
        FeaturesSelfTest.add("tray: image conversions (png/jpeg/heic/tiff) keep the size") {
            clean()
            let png = TraySamples.makeFiles()[0]
            for format in [ConvertFormat.jpeg, .heic, .tiff] {
                guard case .success(let out) = FeaturesSelfTest.block({ try await Converter.convert([png], to: format) { _ in work } }),
                      let size = pixelSize(out[0]), size.width == 640, size.height == 420, out[0].pathExtension == format.ext else { print("  failed: \(format.title)"); return false }
            }
            // The original is untouched.
            return FileManager.default.fileExists(atPath: png.path)
        }
        FeaturesSelfTest.add("tray: images to one PDF, ZIP of one and of several") {
            clean()
            let files = TraySamples.makeFiles()
            let images = [files[0], files[1]]
            guard case .success(let pdf) = FeaturesSelfTest.block({ try await Converter.convert(images, to: .pdf) { _ in work } }),
                  PDFDocument(url: pdf[0])?.pageCount == 2 else { print("  failed: pdf"); return false }
            guard case .success(let one) = FeaturesSelfTest.block({ try await Converter.convert([files[3]], to: .zip) { _ in work } }),
                  case .success(let many) = FeaturesSelfTest.block({ try await Converter.convert([files[3], files[4]], to: .zip) { _ in work } }) else { print("  failed: zip"); return false }
            let listing = Shell.run("/usr/bin/unzip", ["-l", many[0].path]) ?? ""
            return FileManager.default.fileExists(atPath: one[0].path) && listing.contains("Meeting notes.txt") && listing.contains("Budget 2026.csv")
        }
        FeaturesSelfTest.add("tray: the built-in ZIP writer makes valid archives (files, folders, big and tiny)") {
            clean()
            let files = TraySamples.makeFiles()
            let folder = work.appendingPathComponent("Docs", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Inner"), withIntermediateDirectories: true)
            try? "hello".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try? Data().write(to: folder.appendingPathComponent("empty.bin"))
            try? Data((0..<300_000).map { UInt8($0 % 251) }).write(to: folder.appendingPathComponent("Inner/numbers.bin"))
            let out = work.appendingPathComponent("test.zip")
            do { try ZipWriter.write([files[0], files[3], folder], to: out, rootName: "Archive") } catch { print("  write failed: \(error)"); return false }
            guard let names = ZipWriter.verify(out), names.contains("Archive/Meeting notes.txt"), names.contains("Archive/Docs/Inner/numbers.bin"),
                  names.contains("Archive/Docs/empty.bin"), names.contains("Archive/Beach.png") else { print("  verify failed: \(ZipWriter.verify(out) ?? [])"); return false }
            #if !APPSTORE
            let listing = Shell.run("/usr/bin/unzip", ["-t", out.path]) ?? ""
            guard listing.contains("No errors detected") else { print("  unzip -t: \(listing.suffix(200))"); return false }
            #endif
            return true
        }
        FeaturesSelfTest.add("tray: webp, mp4, m4a, mp3 (with the installed tools)") {
            clean()
            var ok = true
            if Converter.hasCwebp {
                let png = TraySamples.makeFiles()[0]
                if case .success(let out) = FeaturesSelfTest.block({ try await Converter.convert([png], to: .webp) { _ in work } }),
                   let head = try? Data(contentsOf: out[0]).prefix(12), String(decoding: head.suffix(4), as: UTF8.self) == "WEBP" {} else { print("  failed: webp"); ok = false }
            }
            #if APPSTORE
            return ok
            #else
            guard Converter.hasFFmpeg else { return ok }
            let movie = work.appendingPathComponent("clip.mov")
            _ = Shell.run(Converter.ffmpegPath, ["-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=15",
                                                  "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-shortest", "-pix_fmt", "yuv420p", "-c:v", "libx264", "-c:a", "aac", movie.path])
            guard FileManager.default.fileExists(atPath: movie.path) else { print("  (could not make a test movie)"); return ok }
            for format in [ConvertFormat.mp4, .m4a, .mp3] {
                guard case .success(let out) = FeaturesSelfTest.block({ try await Converter.convert([movie], to: format) { _ in work } }),
                      (try? FileManager.default.attributesOfItem(atPath: out[0].path)[.size] as? Int ?? 0) ?? 0 > 1000 else { print("  failed: \(format.title)"); ok = false; continue }
            }
            return ok
            #endif
        }
    }

    static func registerGallery() {
        let preview = TrayStore(fileName: "tray-preview.json", folderName: "Tray-Preview")
        TraySamples.fill(preview)
        let empty = TrayStore(fileName: "tray-empty.json", folderName: "Tray-Empty")
        let selected = TrayStore(fileName: "tray-selected.json", folderName: "Tray-Selected")
        TraySamples.fill(selected)
        selected.selection = Set(selected.items.prefix(2).map(\.id))
        selected.convertBarOpen = true

        FeatureGallery.workspace("tray-workspace") { TrayWorkspaceView(store: preview) }
        FeatureGallery.workspace("tray-workspace-convert") { TrayWorkspaceView(store: selected) }
        FeatureGallery.workspace("tray-workspace-empty") { TrayWorkspaceView(store: empty) }
        FeatureGallery.widget("tray-widget", span: 4) { TrayWidgetView(store: preview) }
        FeatureGallery.widget("tray-widget-empty", span: 4) { TrayWidgetView(store: empty) }
        FeatureGallery.workspace("tray-droptargets") { NotchDropTargetsView() }
        FeatureGallery.workspace("tray-droptargets-keep") { NotchDropTargetsView(previewTargeted: .keep) }
        FeatureGallery.workspace("tray-droptargets-convert") { NotchDropTargetsView(previewTargeted: .convert) }
        Gallery.register("tray-result-card", size: CGSize(width: 440, height: 100)) {
            ConversionResultCard(url: TraySamples.makeFiles()[0], extra: 0, format: .webp).background(GlassBackground(cornerRadius: 22))
        }
        FeatureGallery.settings("settings-tray", height: 700) { TraySettingsPane() }
    }
}
