import CryptoKit
import Foundation
import Kit42
import Security

/// Digital signatures in the standard PDF way (adbe.pkcs7.detached, CMS over /ByteRange),
/// compatible with Adobe Acrobat and other validators.
enum PDFSigner {
    struct Options {
        var identity: SigningIdentity
        var reason: String
        var location: String
    }

    /// Reserved bytes for the CMS signature (hex doubles it).
    static let signatureCapacity = 16_384

    /// Appends a signature as an incremental update. `base` must use a classic xref table
    /// (any file saved by PDF42/PDFKit, or a file signed by PDF42).
    static func sign(_ base: Data, options: Options) throws -> Data {
        let file = try PDFFileStructure(base)
        guard case .ref(let rootNum, _)? = file.trailer["Root"], let size = file.trailer["Size"]?.int else {
            throw PDFStructureError.malformed("no /Root")
        }
        var catalog = try file.object(rootNum)

        // First page
        guard case .ref(var pageNum, _)? = catalog["Pages"] else { throw PDFStructureError.malformed("no /Pages") }
        var node = try file.object(pageNum)
        while node["Type"]?.nameValue != "Page" {
            guard case .ref(let kid, _)? = node["Kids"].flatMap({ try? file.resolve($0) })?.items?.first else {
                throw PDFStructureError.malformed("page tree")
            }
            pageNum = kid
            node = try file.object(kid)
        }

        var nextNum = size
        let sigNum = nextNum; nextNum += 1
        let widgetNum = nextNum; nextNum += 1
        let widgetRef = PDFObject.ref(widgetNum, 0)
        var updates: [Int: String] = [:]

        // Page /Annots += widget
        switch node["Annots"] {
        case .array(let a)?:
            updates[pageNum] = node.setting("Annots", .array(a + [widgetRef])).serialized
        case .ref(let n, _)?:
            let arr = try file.object(n).items ?? []
            updates[n] = PDFObject.array(arr + [widgetRef]).serialized
        default:
            updates[pageNum] = node.setting("Annots", .array([widgetRef])).serialized
        }

        // Catalog /AcroForm /Fields += widget, /SigFlags 3
        func addField(_ form: PDFObject) throws -> PDFObject {
            var form = form
            switch form["Fields"] {
            case .array(let a)?: form = form.setting("Fields", .array(a + [widgetRef]))
            case .ref(let n, _)?:
                let arr = try file.object(n).items ?? []
                updates[n] = PDFObject.array(arr + [widgetRef]).serialized
            default: form = form.setting("Fields", .array([widgetRef]))
            }
            return form.setting("SigFlags", .raw("3"))
        }
        switch catalog["AcroForm"] {
        case .ref(let n, _)?:
            updates[n] = try addField(try file.object(n)).serialized
        case .dict?:
            catalog = catalog.setting("AcroForm", try addField(catalog["AcroForm"]!))
            updates[rootNum] = catalog.serialized
        default:
            catalog = catalog.setting("AcroForm", try addField(.dict([])))
            updates[rootNum] = catalog.serialized
        }

        let existingForm = try file.resolve(try file.object(rootNum)["AcroForm"])
        let fieldCount = try file.resolve(existingForm?["Fields"])?.items?.count ?? 0
        updates[widgetNum] = "<< /Type /Annot /Subtype /Widget /FT /Sig /T \(pdfTextString("Signature\(fieldCount + 1)")) /F 132 /Rect [0 0 0 0] /P \(pageNum) \(file.gen(pageNum)) R /V \(sigNum) 0 R >>"

        let byteRangePlaceholder = "[0 0000000000 0000000000 0000000000]"
        let contentsPlaceholder = "<" + String(repeating: "0", count: signatureCapacity * 2) + ">"
        var sig = "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange \(byteRangePlaceholder) /Contents \(contentsPlaceholder) /M \(pdfDate(Date()))"
        sig += " /Name \(pdfTextString(options.identity.name))"
        if !options.reason.isEmpty { sig += " /Reason \(pdfTextString(options.reason))" }
        if !options.location.isEmpty { sig += " /Location \(pdfTextString(options.location))" }
        sig += " /Prop_Build << /App << /Name /PDF42 >> >> >>"
        updates[sigNum] = sig

        // Write the update
        var out = [UInt8](base)
        if out.last != 0x0A { out.append(0x0A) }
        var entries: [(Int, Int)] = []
        var sigOffset = 0
        for num in updates.keys.sorted() {
            entries.append((num, out.count))
            if num == sigNum { sigOffset = out.count }
            let gen = num >= size ? 0 : file.gen(num)
            out += Array("\(num) \(gen) obj\n\(updates[num]!)\nendobj\n".utf8)
        }
        let xrefOffset = out.count
        var xref = "xref\n"
        var i = 0
        while i < entries.count {
            var j = i
            while j + 1 < entries.count, entries[j + 1].0 == entries[j].0 + 1 { j += 1 }
            xref += "\(entries[i].0) \(j - i + 1)\n"
            for k in i...j {
                let num = entries[k].0
                xref += String(format: "%010d %05d n\r\n", entries[k].1, num >= size ? 0 : file.gen(num))
            }
            i = j + 1
        }
        let trailer = file.trailer.removing("XRefStm").removing("Prev")
            .setting("Size", .raw("\(nextNum)")).setting("Prev", .raw("\(file.startxref)"))
        xref += "trailer\n\(trailer.serialized)\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out += Array(xref.utf8)

        // Patch /ByteRange and sign
        guard let brPos = find("/ByteRange ", in: out, from: sigOffset),
              let contentsPos = find("/Contents <", in: out, from: sigOffset) else {
            throw PDFStructureError.malformed("signature placeholder")
        }
        let a = contentsPos + "/Contents ".utf8.count
        let b = a + contentsPlaceholder.utf8.count
        let range = "[0 \(a) \(b) \(out.count - b)]"
        let padded = range.padding(toLength: byteRangePlaceholder.count, withPad: " ", startingAt: 0)
        let brStart = brPos + "/ByteRange ".utf8.count
        out.replaceSubrange(brStart..<brStart + padded.utf8.count, with: Array(padded.utf8))

        let signed = Data(out[0..<a] + out[b..<out.count])
        let cms = try cmsSign(signed, identity: options.identity.identity)
        guard cms.count <= signatureCapacity else { throw PDFStructureError.unsupported(L("the signature is too large (%d bytes)", cms.count)) }
        let hex = cms.map { String(format: "%02X", $0) }.joined()
        out.replaceSubrange(a + 1..<a + 1 + hex.utf8.count, with: Array(hex.utf8))
        return Data(out)
    }

    static func cmsSign(_ data: Data, identity: SecIdentity) throws -> Data {
        var encoder: CMSEncoder?
        try check(CMSEncoderCreate(&encoder), "CMS")
        guard let encoder else { throw CertificateError.failed("CMS") }
        try check(CMSEncoderAddSigners(encoder, identity), "signing key")
        try check(CMSEncoderSetHasDetachedContent(encoder, true), "CMS")
        try check(CMSEncoderSetSignerAlgorithm(encoder, kCMSEncoderDigestAlgorithmSHA256), "SHA-256")
        try check(CMSEncoderAddSignedAttributes(encoder, .attrSigningTime), "signing time")
        try check(CMSEncoderSetCertificateChainMode(encoder, .chainWithRoot), "certificate chain")
        try data.withUnsafeBytes { try check(CMSEncoderUpdateContent(encoder, $0.baseAddress!, data.count), "data") }
        var out: CFData?
        try check(CMSEncoderCopyEncodedContent(encoder, &out), L("signature (access to the key denied?)"))
        guard let out else { throw CertificateError.failed("empty signature") }
        return out as Data
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == errSecSuccess else {
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            throw CertificateError.failed("\(what): \(msg)")
        }
    }

    static func pdfDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        let tz = TimeZone.current.secondsFromGMT(for: date)
        let sign = tz >= 0 ? "+" : "-"
        return String(format: "(D:%@%@%02d'%02d')", f.string(from: date), sign, abs(tz) / 3600, abs(tz) % 3600 / 60)
    }

    static func find(_ s: String, in bytes: [UInt8], from: Int) -> Int? {
        let needle = Array(s.utf8)
        var i = from
        while i + needle.count <= bytes.count {
            if bytes[i] == needle[0], Array(bytes[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }
}

enum CertificateError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let s) = self { return L("Could not sign: %@", s) }
        return nil
    }
}

/// Result of checking one signature.
struct SignatureInfo {
    enum Status { case valid, untrusted, invalid }

    var signer = L("Unknown")
    var email: String?
    var date: Date?
    var reason: String?
    var location: String?
    var status: Status = .invalid
    var coversWholeFile = false
    var trustMessage: String?
    var problem: String?

    var summary: String {
        switch status {
        case .valid: return coversWholeFile ? L("Signature is valid") : L("Valid for its version; the document was extended after signing")
        case .untrusted: return L("The signature is intact, but the certificate is not verified")
        case .invalid: return problem ?? L("Signature is invalid")
        }
    }
}

enum PDFSignatureVerifier {
    static func verify(_ data: Data) -> [SignatureInfo] {
        let bytes = [UInt8](data)
        var results: [SignatureInfo] = []
        var pos = 0
        while let br = PDFSigner.find("/ByteRange", in: bytes, from: pos) {
            pos = br + 10
            var lexer = PDFLexer(bytes: bytes, pos: pos)
            guard let range = (try? lexer.parse())?.items?.compactMap(\.int), range.count == 4 else { continue }
            let (a, b, c, d) = (range[0], range[1], range[2], range[3])
            guard a == 0, b > 0, c > b, c + d <= bytes.count, bytes[b] == UInt8(ascii: "<"), bytes[c - 1] == UInt8(ascii: ">") else { continue }
            var info = SignatureInfo()
            info.coversWholeFile = c + d == bytes.count
            readDictionary(bytes, around: br, contents: b..<c, into: &info)
            let cms = hexDecode(bytes[(b + 1)..<(c - 1)])
            let signed = Data(bytes[0..<b] + bytes[c..<(c + d)])
            check(cms: cms, signed: signed, into: &info)
            results.append(info)
        }
        return results
    }

    private static func check(cms: Data, signed: Data, into info: inout SignatureInfo) {
        let message = derTrimmed(cms)
        func decoder(detached: Data?) -> CMSDecoder? {
            var d: CMSDecoder?
            guard CMSDecoderCreate(&d) == errSecSuccess, let d else { return nil }
            let ok = message.withUnsafeBytes { CMSDecoderUpdateMessage(d, $0.baseAddress!, message.count) } == errSecSuccess
            if let detached { CMSDecoderSetDetachedContent(d, detached as CFData) }
            guard ok, CMSDecoderFinalizeMessage(d) == errSecSuccess else { return nil }
            return d
        }
        guard let probe = decoder(detached: nil) else {
            info.problem = L("The signature is damaged (CMS cannot be read)")
            return
        }
        // Detached (adbe.pkcs7.detached, ETSI.CAdES.detached) has no embedded content;
        // adbe.pkcs7.sha1 embeds the SHA-1 of the byte range.
        var embedded: CFData?
        CMSDecoderCopyContent(probe, &embedded)
        var dec = probe
        if let content = embedded as Data?, !content.isEmpty {
            if content != Data(Insecure.SHA1.hash(data: signed)) {
                info.problem = L("The document was changed after signing")
            }
        } else {
            guard let d = decoder(detached: signed) else { info.problem = L("The signature is damaged"); return }
            dec = d
        }

        var cert: SecCertificate?
        if CMSDecoderCopySignerCert(dec, 0, &cert) == errSecSuccess, let cert {
            info.signer = SecCertificateCopySubjectSummary(cert) as String? ?? info.signer
            var emails: CFArray?
            SecCertificateCopyEmailAddresses(cert, &emails)
            info.email = (emails as? [String])?.first
        }
        var time: CFAbsoluteTime = 0
        if CMSDecoderCopySignerSigningTime(dec, 0, &time) == errSecSuccess {
            info.date = Date(timeIntervalSinceReferenceDate: time)
        }

        var status: CMSSignerStatus = .unsigned
        var trust: SecTrust?
        var verifyCode: OSStatus = 0
        CMSDecoderCopySignerStatus(dec, 0, SecPolicyCreateBasicX509(), true, &status, &trust, &verifyCode)
        if let trust {
            var error: CFError?
            if !SecTrustEvaluateWithError(trust, &error) {
                info.trustMessage = (error as Error?)?.localizedDescription
            }
        }
        if info.problem != nil { info.status = .invalid; return }
        switch status {
        case .valid: info.status = .valid
        case .invalidCert: info.status = .untrusted
        case .invalidSignature: info.status = .invalid; info.problem = L("The document was changed after signing")
        default: info.status = .invalid; info.problem = L("The signature could not be verified")
        }
    }

    /// Reads /Reason, /Location, /M, /Name from the signature dictionary that holds this /ByteRange.
    private static func readDictionary(_ bytes: [UInt8], around pos: Int, contents: Range<Int>, into info: inout SignatureInfo) {
        let start = max(0, pos - 4096)
        let before = Array(bytes[start..<contents.lowerBound])
        let after = Array(bytes[contents.upperBound..<min(bytes.count, contents.upperBound + 4096)])
        var region = before + after
        if let objStart = PDFFileStructure.lastIndex(of: " obj", in: before) { region = Array(before[objStart...]) + after }
        if let end = PDFSigner.find("endobj", in: region, from: 0) { region = Array(region[..<end]) }
        func value(_ key: String) -> String? {
            guard let p = PDFSigner.find("/\(key)", in: region, from: 0) else { return nil }
            var lexer = PDFLexer(bytes: region, pos: p + key.utf8.count + 1)
            guard case .raw(let raw)? = try? lexer.parse() else { return nil }
            let s = decodePDFString(raw)
            return s.isEmpty ? nil : s
        }
        info.reason = value("Reason")
        info.location = value("Location")
        if let name = value("Name") { info.signer = name }
        if let m = value("M") { info.date = parsePDFDate(m) }
    }

    static func parsePDFDate(_ s: String) -> Date? {
        let digits = s.replacingOccurrences(of: "D:", with: "").prefix(14)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: String(digits))
    }

    private static func hexDecode(_ hex: ArraySlice<UInt8>) -> Data {
        var out = Data(capacity: hex.count / 2)
        var high: UInt8?
        for c in hex {
            let v: UInt8
            switch c {
            case 0x30...0x39: v = c - 0x30
            case 0x41...0x46: v = c - 0x41 + 10
            case 0x61...0x66: v = c - 0x61 + 10
            default: continue
            }
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        return out
    }

    /// Drops the zero padding after the CMS message (BER, possibly indefinite-length).
    private static func derTrimmed(_ data: Data) -> Data {
        let b = [UInt8](data)
        guard let length = berLength(b, at: 0) else { return data }
        return data.prefix(length)
    }

    /// Total size of the BER element starting at `i`, or nil if malformed.
    private static func berLength(_ b: [UInt8], at start: Int) -> Int? {
        var i = start
        guard i < b.count else { return nil }
        if b[i] & 0x1F == 0x1F {
            i += 1
            while i < b.count, b[i] & 0x80 != 0 { i += 1 }
        }
        i += 1
        guard i < b.count else { return nil }
        let first = b[i]
        i += 1
        if first == 0x80 {
            // Indefinite length: children until the 00 00 end-of-contents marker.
            while i + 1 < b.count {
                if b[i] == 0, b[i + 1] == 0 { return i + 2 - start }
                guard let child = berLength(b, at: i) else { return nil }
                i += child
            }
            return nil
        }
        var len = 0
        if first & 0x80 == 0 { len = Int(first) } else {
            let n = Int(first & 0x7F)
            guard n <= 4, i + n <= b.count else { return nil }
            for k in 0..<n { len = len << 8 | Int(b[i + k]) }
            i += n
        }
        return i + len - start <= b.count ? i + len - start : nil
    }
}
