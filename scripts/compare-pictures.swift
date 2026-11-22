// Compares two folders of PNG pictures pixel by pixel.
// Usage: swift scripts/compare-pictures.swift <base> <candidate> [--stable <base again>] [--stable2 <candidate again>] [--grow <pixels>] [--diff <out folder>]
// A pixel that differs between <base> and <base again> (or between <candidate> and <candidate again>) changes by itself from one render to
// the next (a clock, a date, an animation): it is masked and never counted. --grow widens every masked spot by that many pixels on each
// side: a blinking face shows a third frame in a third render, right beside the pixels the two renders caught. Prints one line per picture
// that differs, is new or is gone, then a summary. With --diff a picture of the differing pixels (red on the dimmed base) is written for
// each differing picture.
// Exit 0: every shared picture is the same outside the masks. Exit 1: something differs or a picture is gone. Exit 64: wrong arguments.
import AppKit

struct Bitmap {
    let width: Int
    let height: Int
    var bytes: [UInt8]   // RGBA, 8 bits each, premultiplied
}

func load(_ url: URL) -> Bitmap? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drawn ? Bitmap(width: width, height: height, bytes: bytes) : nil
}

func pictures(_ folder: URL) -> [String: URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension == "png" }.map { ($0.lastPathComponent, $0) })
}

/// True where the two bitmaps differ (same size required).
func differing(_ a: Bitmap, _ b: Bitmap) -> [Bool] {
    var out = [Bool](repeating: false, count: a.width * a.height)
    for i in 0..<out.count {
        let k = i * 4
        if a.bytes[k] != b.bytes[k] || a.bytes[k + 1] != b.bytes[k + 1] || a.bytes[k + 2] != b.bytes[k + 2] || a.bytes[k + 3] != b.bytes[k + 3] { out[i] = true }
    }
    return out
}

func writeDiff(base: Bitmap, marks: [Bool], to url: URL) {
    var bytes = base.bytes
    for i in 0..<marks.count {
        let k = i * 4
        if marks[i] {
            bytes[k] = 255; bytes[k + 1] = 0; bytes[k + 2] = 0; bytes[k + 3] = 255
        } else {
            bytes[k] = UInt8(Int(bytes[k]) / 3 + 40); bytes[k + 1] = UInt8(Int(bytes[k + 1]) / 3 + 40); bytes[k + 2] = UInt8(Int(bytes[k + 2]) / 3 + 40); bytes[k + 3] = 255
        }
    }
    bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: base.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> URL? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    let url = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
    arguments.removeSubrange(i...(i + 1))
    return url
}
let stableBase = option("--stable"), stableCandidate = option("--stable2"), diffFolder = option("--diff")
var grow = 0
if let i = arguments.firstIndex(of: "--grow"), i + 1 < arguments.count {
    grow = max(0, Int(arguments[i + 1]) ?? 0)
    arguments.removeSubrange(i...(i + 1))
}
guard arguments.count == 2 else {
    print("usage: compare-pictures.swift <base> <candidate> [--stable <base again>] [--stable2 <candidate again>] [--grow <pixels>] [--diff <out folder>]")
    exit(64)
}

/// Every masked pixel also masks the square of `radius` pixels around it.
func grown(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
    guard radius > 0 else { return mask }
    var out = mask
    for y in 0..<height {
        for x in 0..<width where mask[y * width + x] {
            for yy in max(0, y - radius)...min(height - 1, y + radius) {
                for xx in max(0, x - radius)...min(width - 1, x + radius) { out[yy * width + xx] = true }
            }
        }
    }
    return out
}
let base = pictures(URL(fileURLWithPath: arguments[0], isDirectory: true)), candidate = pictures(URL(fileURLWithPath: arguments[1], isDirectory: true))
let baseAgain = stableBase.map(pictures) ?? [:], candidateAgain = stableCandidate.map(pictures) ?? [:]
if let diffFolder { try? FileManager.default.createDirectory(at: diffFolder, withIntermediateDirectories: true) }

var same = 0, different = 0, masked = 0
let gone = base.keys.filter { candidate[$0] == nil }.sorted(), added = candidate.keys.filter { base[$0] == nil }.sorted()
for name in base.keys.sorted() {
    guard let other = candidate[name] else { continue }
    guard let a = load(base[name]!), let b = load(other) else { print("UNREADABLE  \(name)"); different += 1; continue }
    guard a.width == b.width, a.height == b.height else {
        print("SIZE        \(name): \(a.width)x\(a.height) -> \(b.width)x\(b.height)")
        different += 1
        continue
    }
    var mask = [Bool](repeating: false, count: a.width * a.height)
    for (again, first) in [(baseAgain[name], a), (candidateAgain[name], b)] {
        guard let again, let second = load(again), second.width == first.width, second.height == first.height else { continue }
        let unstable = differing(first, second)
        for i in 0..<mask.count where unstable[i] { mask[i] = true }
    }
    mask = grown(mask, width: a.width, height: a.height, radius: grow)
    var marks = differing(a, b)
    var count = 0
    for i in 0..<marks.count {
        if mask[i] { marks[i] = false } else if marks[i] { count += 1 }
    }
    let maskedHere = mask.filter { $0 }.count
    if maskedHere > 0 { masked += 1 }
    if count == 0 {
        same += 1
        if maskedHere > 0 { print("same        \(name) (\(maskedHere) px change by themselves and are masked)") }
    } else {
        different += 1
        print("DIFFERENT   \(name): \(count) px\(maskedHere > 0 ? " (\(maskedHere) px masked)" : "")")
        if let diffFolder { writeDiff(base: a, marks: marks, to: diffFolder.appendingPathComponent(name)) }
    }
}
for name in gone { print("GONE        \(name)") }
for name in added { print("NEW         \(name)") }
print("compare: \(same) the same, \(different) different, \(gone.count) gone, \(added.count) new (\(masked) with masked pixels)")
exit(different == 0 && gone.isEmpty ? 0 : 1)
