import AppKit
import Previews42

// Development tool: renders what the Quick Look extensions produce, without Quick Look.
//   ql42render html <file> <out.html>
//   ql42render thumb <file> <size> <out.png>
let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: ql42render html <file> <out.html> | thumb <file> <size> <out.png>\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args[2])
if args[1] == "html" {
    try Previews42.html(for: input).write(toFile: args[3], atomically: true, encoding: .utf8)
} else if args.count >= 5, let side = Double(args[3]) {
    let t = try Previews42.thumbnail(for: input, maximumSize: CGSize(width: side, height: side))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(t.size.width), pixelsHigh: Int(t.size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    _ = t.draw(ctx)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[4]))
}
