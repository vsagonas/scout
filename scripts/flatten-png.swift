// Re-writes PNGs as plain RGB (no alpha channel), pixel size unchanged: App Store Connect wants flattened screenshots.
// Usage: swift scripts/flatten-png.swift <input-dir> <output-dir> [name-prefix]   (only files starting with the prefix)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: flatten-png.swift <input-dir> <output-dir> [prefix]"); exit(64) }
let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
let prefix = args.count > 3 ? args[3] : ""
let fm = FileManager.default
try fm.createDirectory(at: output, withIntermediateDirectories: true)
var count = 0
for name in try fm.contentsOfDirectory(atPath: input.path).sorted() where name.hasSuffix(".png") && name.hasPrefix(prefix) {
    guard let source = CGImageSourceCreateWithURL(input.appendingPathComponent(name) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { print("skipped \(name)"); continue }
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let flat = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { continue }
    CGImageDestinationAddImage(dest, flat, nil)
    CGImageDestinationFinalize(dest)
    count += 1
}
print("Flattened \(count) images into \(output.path)")
