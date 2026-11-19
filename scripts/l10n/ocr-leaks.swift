import AppKit
import Vision

// Reads gallery PNGs rendered in the pseudo language (SCOUT_LANG=pseudo) and prints the lines that look like unlocalized English:
// a line with a word of 4 or more plain letters and no accented letter and no "[!" / "!]" marker (every localized pseudo line has them).
// Usage: swiftc -O scripts/l10n/ocr-leaks.swift -o /tmp/ocr-leaks && /tmp/ocr-leaks <folder-or-png ...>
// Dark galleries are skipped (the light ones show the same text). Output: <image>\t<line>
let accents = Set("àéîöüÀÉÎÖÜýÝ")
func isLeak(_ line: String) -> Bool {
    if line.contains("[!") || line.contains("!]") || line.contains(where: { accents.contains($0) }) { return false }
    let words = line.split { !$0.isLetter }
    return words.contains { $0.count >= 4 && $0.allSatisfy { $0.isASCII } && $0.contains(where: { "aeiouy".contains($0.lowercased()) }) }
}
var files: [URL] = []
for arg in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: arg)
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: arg, isDirectory: &isDir)
    if isDir.boolValue {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: arg)) ?? []
        files += names.filter { $0.hasSuffix("-light.png") }.sorted().map { url.appendingPathComponent($0) }
    } else { files.append(url) }
}
for file in files {
    guard let image = NSImage(contentsOf: file), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try? handler.perform([request])
    for obs in request.results ?? [] {
        guard let text = obs.topCandidates(1).first?.string else { continue }
        if isLeak(text) { print("\(file.lastPathComponent)\t\(text)") }
    }
}
