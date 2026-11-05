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
if args.count >= 2, args[1] == "--selftest" {
    let basic = PDFSelfTest.run(), deep = PDFFilesAudit.run()
    exit(basic == 0 && deep == 0 ? 0 : 1)
}
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
// GOST signatures and detached-file operations use the dedicated CSP command handler.
if let code = GOSTCLI.run(args) { exit(code) }
if let code = PDFMainCLI.run(args) { exit(code) }

if let code = ToolsCLI.run(args) { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
