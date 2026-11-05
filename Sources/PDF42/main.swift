import AppKit
import Kit42
import PDFKit

// Command-line helpers for testing signatures without the UI:
//   PDF42 --verify file.pdf
//   PDF42 --sign in.pdf identity.p12 password out.pdf [visible] [tsa | tsa=URL] [level=pkcs7|B-B|B-T|B-LT|B-LTA]
//   PDF42 --ltv in.pdf out.pdf                          (DSS with certificates, OCSP, CRLs for every signature)
//   PDF42 --doc-timestamp in.pdf out.pdf [TSA-URL]      (RFC 3161 document timestamp; B-LTA for signed files)
//   PDF42 --csc-credentials SERVICE-URL [auth…]          (CSC API v2: list credentials)
//   PDF42 --csc-sign in.pdf out.pdf SERVICE-URL CREDENTIAL-ID [auth…] [pin=…] [otp=…] [tsa=URL] [level=…]
//   auth: token=… | user=… password=… | client-id=… [client-secret=…] [port=8765] [no-browser]
Localization.register(rows: pdf42Strings)

let args = CommandLine.arguments
if args.count >= 2, args[1] == "--selftest" { exit(PDFSelfTest.run()) }
// PDF42 --mark-overlay DIR: a page of text with a stamp and a signature over it, saved and reopened,
// with multiply (ink) and, for comparison, normal blending.
if args.count >= 3, args[1] == "--mark-overlay" {
    try MarkOverlayDemo.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}
// PDF42 --mark-samples DIR: generated signatures and stamps for visual review.
if args.count >= 3, args[1] == "--mark-samples" {
    try MarkSamples.write(to: URL(fileURLWithPath: args[2]))
    let count = (try? FileManager.default.contentsOfDirectory(atPath: args[2]).filter { $0.hasSuffix(".png") }.count) ?? 0
    print("Mark samples: \(count) files")
    exit(0)
}
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
        let ltv = s.ltvEnabled.map { $0 ? "yes" : "no (\(s.ltvProblem ?? ""))" } ?? "-"
        print("\(s.isDocumentTimestamp ? "doc-timestamp" : "signature") | \(s.status) | \(s.signer) | whole=\(s.coversWholeFile) | \(s.reason ?? "-") | ts=\(s.timestamp.map { "\($0)" } ?? "none") | level=\(s.level ?? "-") | ltv=\(ltv) | \(s.problem ?? s.trustMessage ?? "")")
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
    applySignArguments(&options)
    let signed = try PAdES.sign(base, options: options)
    signed.warnings.forEach { print("warning: \($0)") }
    try signed.data.write(to: URL(fileURLWithPath: args[5]))
    print("signed \(signed.data.count) bytes, \(options.level.cliName)")
    exit(0)
}

/// key=value argument.
func argument(_ key: String) -> String? {
    args.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
}

func applySignArguments(_ options: inout PDFSigner.Options) {
    if args.contains("tsa") { options.timestampURL = URL(string: "http://timestamp.digicert.com") }
    if let t = argument("tsa") { options.timestampURL = URL(string: t) }
    options.level = argument("level").flatMap(PAdESLevel.named) ?? (options.timestampURL != nil ? .baselineT : .baselineB)
    // B-B is the level without a timestamp.
    if options.level == .baselineB { options.timestampURL = nil }
}

func cscClient(_ url: String) -> CSCClient {
    guard let base = URL(string: url) else { print("bad URL \(url)"); exit(1) }
    var config = CSCClient.Config(baseURL: base)
    config.accessToken = argument("token")
    config.username = argument("user")
    config.password = argument("password")
    config.clientID = argument("client-id")
    config.clientSecret = argument("client-secret")
    if let p = argument("port").flatMap(UInt16.init) { config.redirectPort = p }
    config.openURL = { url in
        print("Open to authorize: \(url.absoluteString)")
        fflush(stdout)
        if !args.contains("no-browser") { NSWorkspace.shared.open(url) }
    }
    return CSCClient(config)
}

if args.count >= 4, args[1] == "--ltv" {
    let result = try PAdES.addValidationData(try Data(contentsOf: URL(fileURLWithPath: args[2])))
    result.warnings.forEach { print("warning: \($0)") }
    try result.data.write(to: URL(fileURLWithPath: args[3]))
    print("ltv \(result.data.count) bytes")
    exit(0)
}
if args.count >= 4, args[1] == "--doc-timestamp" {
    let input = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let signed = !PDFSignatureVerifier.verify(input).isEmpty
    let base = signed ? input : PDFDocument(data: input)!.dataRepresentation()!
    let tsa = URL(string: args.count > 4 ? args[4] : "http://timestamp.digicert.com")!
    var result = PAdES.Result(data: try PAdES.addDocumentTimestamp(base, tsa: tsa))
    if signed { result = try PAdES.addValidationData(result.data) }
    result.warnings.forEach { print("warning: \($0)") }
    try result.data.write(to: URL(fileURLWithPath: args[3]))
    print("timestamped \(result.data.count) bytes")
    exit(0)
}
if args.count >= 3, args[1] == "--csc-credentials" {
    let client = cscClient(args[2])
    do {
        if let info = try? client.loadInfo() { print("service: \(info["name"] ?? "?") | auth: \(client.authTypes.joined(separator: ","))") }
        for c in try client.listCredentials() {
            print("\(c.id) | \(c.chain.first?.name ?? "-") | chain=\(c.chain.count) | auth=\(c.authMode) pin=\(c.needsPIN) otp=\(c.needsOTP) | algo=\(c.algorithms.joined(separator: ","))")
        }
    } catch { print("error: \(error.localizedDescription)"); exit(1) }
    exit(0)
}
if args.count >= 6, args[1] == "--csc-sign" {
    let input = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let client = cscClient(args[4])
    do {
        let credential = try client.credential(args[5])
        let signer = CSCSigner(client: client, credential: credential) { _ in (argument("pin"), argument("otp")) }
        let base = PDFSignatureVerifier.verify(input).isEmpty ? PDFDocument(data: input)!.dataRepresentation()! : input
        var options = PDFSigner.Options(identity: nil, reason: argument("reason") ?? "Remote signature test", location: "")
        options.remote = signer
        applySignArguments(&options)
        let signed = try PAdES.sign(base, options: options)
        signed.warnings.forEach { print("warning: \($0)") }
        try signed.data.write(to: URL(fileURLWithPath: args[3]))
        print("signed remotely \(signed.data.count) bytes, \(options.level.cliName)")
    } catch { print("error: \(error.localizedDescription)"); exit(1) }
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

if let code = ToolsCLI.run(args) { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
