import AppKit
import Kit42
import PDFKit

// Command-line helpers for testing signatures without the UI:
//   PDF42 --verify file.pdf
//   PDF42 --sign in.pdf identity.p12 password out.pdf
Localization.register(rows: pdf42Strings)

let args = CommandLine.arguments
// PDF42 --compress in.pdf out.pdf [smallest|balanced|high]
if args.count >= 4, args[1] == "--compress" {
    let input = URL(fileURLWithPath: args[2])
    let original = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let level = args.count > 4 ? PDFCompressor.Level.named(args[4]) ?? .balanced : .balanced
    guard let doc = PDFDocument(url: input) else { print("cannot open"); exit(1) }
    if let data = PDFCompressor.compress(doc, level: level, original: original) {
        try data.write(to: URL(fileURLWithPath: args[3]))
        print("\(level): \(original) -> \(data.count) bytes")
    } else {
        print("\(level): no gain (\(original) bytes)")
    }
    exit(0)
}
if args.count >= 3, args[1] == "--verify" {
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    for s in PDFSignatureVerifier.verify(data) {
        print("\(s.status) | \(s.signer) | whole=\(s.coversWholeFile) | \(s.reason ?? "-") | ts=\(s.timestamp.map { "\($0)" } ?? "none") | \(s.trustMessage ?? "")")
    }
    exit(0)
}
if args.count >= 6, args[1] == "--sign" {
    let input = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let identity = try CertificateStore.importPKCS12(try Data(contentsOf: URL(fileURLWithPath: args[3])), password: args[4], toKeychain: false)
    // Same path as the UI: normalise with PDFKit unless the file is already signed.
    let base = PDFSignatureVerifier.verify(input).isEmpty ? PDFDocument(data: input)!.dataRepresentation()! : input
    var options = PDFSigner.Options(identity: identity, reason: "Signature test", location: "Moscow")
    if args.contains("visible") {
        let size = CGSize(width: 220, height: 72)
        options.visible = (0, CGRect(x: 340, y: 40, width: size.width, height: size.height),
                           EditorWindowController.signatureAppearance(size: size, image: nil, name: identity.name, reason: "Signature test", date: Date()))
    }
    if args.contains("tsa") { options.timestampURL = URL(string: "http://timestamp.digicert.com") }
    let signed = try PDFSigner.sign(base, options: options)
    try signed.write(to: URL(fileURLWithPath: args[5]))
    print("signed \(signed.count) bytes")
    exit(0)
}

// PDF42 --export in.pdf out.(docx|txt) ; PDF42 --images-to-pdf out.pdf a.png b.jpg …
if args.count >= 4, args[1] == "--export" {
    let pdf = PDFDocument(url: URL(fileURLWithPath: args[2]))!
    let out = URL(fileURLWithPath: args[3])
    let data = out.pathExtension == "docx" ? DocxWriter.data(PDFDoc.attributedText(pdf)) : Data((pdf.string ?? "").utf8)
    try data.write(to: out)
    print("\(out.pathExtension): \(data.count) bytes")
    exit(0)
}
if args.count >= 4, args[1] == "--images-to-pdf" {
    let pdf = PDFDocument()
    for path in args.dropFirst(3) { if let img = NSImage(contentsOfFile: path), let p = PDFDoc.page(from: img) { pdf.insert(p, at: pdf.pageCount) } }
    pdf.write(to: URL(fileURLWithPath: args[2]))
    print("pages: \(pdf.pageCount)")
    exit(0)
}

// PDF42 --ocr in.pdf out.pdf
if args.count >= 4, args[1] == "--ocr" {
    let pdf = PDFDocument(url: URL(fileURLWithPath: args[2]))!
    for i in 0..<pdf.pageCount {
        if let page = pdf.page(at: i), let ocr = EditorWindowController.ocrPage(page) { pdf.removePage(at: i); pdf.insert(ocr, at: i) }
    }
    pdf.write(to: URL(fileURLWithPath: args[3]))
    print("ocr pages: \(pdf.pageCount)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
