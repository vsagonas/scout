// Contact sheet: lays out PNGs from a folder in a labelled grid (one or more sheets).
// Usage: swift scripts/contact-sheet.swift <inDir> <outPrefix> [columns=3] [cellWidth=520] [filter-substring]
// Writes <outPrefix>-1.png, <outPrefix>-2.png … (at most 12 images per sheet).
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: contact-sheet.swift <inDir> <outPrefix> [columns] [cellWidth] [filter]")
    exit(1)
}
let inDir = URL(fileURLWithPath: args[1])
let outPrefix = args[2]
let columns = args.count > 3 ? Int(args[3]) ?? 3 : 3
let cellWidth = CGFloat(args.count > 4 ? Double(args[4]) ?? 520 : 520)
let filter = args.count > 5 ? args[5] : ""
let perSheet = 12
let labelHeight: CGFloat = 26
let pad: CGFloat = 14

let files = (try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension == "png" && (filter.isEmpty || $0.lastPathComponent.contains(filter)) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
guard !files.isEmpty else { print("no images"); exit(0) }

var sheetIndex = 0
for chunkStart in stride(from: 0, to: files.count, by: perSheet) {
    sheetIndex += 1
    let chunk = Array(files[chunkStart..<min(chunkStart + perSheet, files.count)])
    let images = chunk.compactMap { NSImage(contentsOf: $0) }
    // Row heights from each image's aspect ratio at cellWidth.
    var rowHeights: [CGFloat] = []
    for row in stride(from: 0, to: images.count, by: columns) {
        let slice = images[row..<min(row + columns, images.count)]
        let h = slice.map { img -> CGFloat in
            let s = img.size
            return s.width > 0 ? cellWidth * s.height / s.width : cellWidth
        }.max() ?? cellWidth
        rowHeights.append(h + labelHeight)
    }
    let width = pad + CGFloat(columns) * (cellWidth + pad)
    let height = pad + rowHeights.reduce(0) { $0 + $1 + pad }
    let canvas = NSImage(size: CGSize(width: width, height: height))
    canvas.lockFocus()
    NSColor(white: 0.5, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    var y = height - pad
    for (r, rowHeight) in rowHeights.enumerated() {
        y -= rowHeight
        for c in 0..<columns {
            let i = r * columns + c
            guard i < images.count else { break }
            let img = images[i]
            let x = pad + CGFloat(c) * (cellWidth + pad)
            let ih = img.size.width > 0 ? cellWidth * img.size.height / img.size.width : cellWidth
            img.draw(in: NSRect(x: x, y: y + rowHeight - labelHeight - ih, width: cellWidth, height: ih))
            let name = chunk[i].deletingPathExtension().lastPathComponent as NSString
            name.draw(at: CGPoint(x: x, y: y + rowHeight - labelHeight + 6),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white])
        }
        y -= pad
    }
    canvas.unlockFocus()
    guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let out = URL(fileURLWithPath: "\(outPrefix)-\(sheetIndex).png")
    try? png.write(to: out)
    print(out.path)
}
