import AppKit
import Kit42

/// Dialogs for digital signatures: choose certificate, import/create, show verification results.
enum SignDialog {
    static func run(stampSelected: Bool) -> (options: PDFSigner.Options, visible: Bool)? {
        var identities = CertificateStore.identities()
        var remotes: [CSCSigner] = []
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        func fill(select name: String? = nil) {
            popup.removeAllItems()
            let titles = identities.map(\.displayName) + remotes.map { "☁︎ " + $0.credential.label }
            popup.addItems(withTitles: titles)
            if titles.isEmpty { popup.addItem(withTitle: L("No certificates")) }
            if let name, let i = titles.firstIndex(of: name) { popup.selectItem(at: i) }
            popup.isEnabled = !titles.isEmpty
        }
        fill()

        let reason = NSTextField(string: UserDefaults.standard.string(forKey: "sign.reason") ?? L("I agree with the content of this document"))
        let location = NSTextField(string: UserDefaults.standard.string(forKey: "sign.location") ?? "")
        location.placeholderString = L("City (optional)")

        let actions = ButtonRow()
        actions.add(L("Import .p12…")) {
            if let id = importCertificate() { identities = CertificateStore.identities(); fill(select: id.displayName) }
        }
        actions.add(L("Create…")) {
            if let id = createCertificate() { identities = CertificateStore.identities(); fill(select: id.displayName) }
        }
        actions.add(L("Remote (CSC)…")) {
            if let signer = connectRemote() { remotes.append(signer); fill(select: "☁︎ " + signer.credential.label) }
        }

        let d = UserDefaults.standard
        let visible = NSButton(checkboxWithTitle: stampSelected ? L("Visible signature (in place of the selected image)") : L("Visible signature (bottom right of the current page)"),
                               target: nil, action: nil)
        visible.state = stampSelected || d.bool(forKey: "sign.visible") ? .on : .off
        let timestamp = NSButton(checkboxWithTitle: L("Add a trusted timestamp (needs internet)"), target: nil, action: nil)
        timestamp.state = d.object(forKey: "sign.tsa") == nil || d.bool(forKey: "sign.tsa") ? .on : .off
        let tsa = NSTextField(string: d.string(forKey: "sign.tsaURL") ?? "http://timestamp.digicert.com")
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: PAdESLevel.allCases.map(\.title))
        format.selectItem(at: d.object(forKey: "sign.level") == nil ? PAdESLevel.baselineLTA.rawValue : d.integer(forKey: "sign.level"))
        let alert = NSAlert.form(L("Sign Document"),
                                 info: L("The signature is added to a copy of the document. Certificates come from the macOS Keychain or a remote signing service (CSC). Long-term levels (B-T and above) need the timestamp server."),
                                 ok: L("Sign…"),
                                 rows: [(L("Certificate:"), popup), ("", actions), (L("Reason:"), reason), (L("Location:"), location),
                                        ("", visible), (L("Format:"), format), ("", timestamp), (L("TSA server:"), tsa)])
        alert.icon = Theme42.symbol("checkmark.seal.fill", size: 40)
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let index = popup.indexOfSelectedItem
            guard index >= 0, index < identities.count + remotes.count else {
                NSSound.beep()
                continue
            }
            d.set(reason.stringValue, forKey: "sign.reason")
            d.set(location.stringValue, forKey: "sign.location")
            d.set(visible.state == .on, forKey: "sign.visible")
            d.set(timestamp.state == .on, forKey: "sign.tsa")
            d.set(tsa.stringValue, forKey: "sign.tsaURL")
            d.set(format.indexOfSelectedItem, forKey: "sign.level")
            var o = PDFSigner.Options(identity: index < identities.count ? identities[index] : nil, reason: reason.stringValue, location: location.stringValue)
            if index >= identities.count { o.remote = remotes[index - identities.count] }
            o.level = PAdESLevel(rawValue: format.indexOfSelectedItem) ?? .baselineB
            if timestamp.state == .on { o.timestampURL = URL(string: tsa.stringValue.trimmingCharacters(in: .whitespaces)) }
            if o.level >= .baselineT, o.timestampURL == nil {
                let ask = NSAlert()
                ask.messageText = L("%@ needs a trusted timestamp", o.level.title)
                ask.informativeText = L("Turn on the timestamp, or the document is signed as PAdES B-B.")
                ask.addButton(withTitle: L("Sign as B-B"))
                ask.addButton(withTitle: L("Cancel"))
                guard ask.runModal() == .alertFirstButtonReturn else { continue }
            }
            return (o, visible.state == .on)
        }
    }

    /// Connects to a Cloud Signature Consortium (API v2) service and picks a credential.
    static func connectRemote() -> CSCSigner? {
        let d = UserDefaults.standard
        let url = NSTextField(string: d.string(forKey: "csc.url") ?? "")
        url.placeholderString = "https://provider.example/csc/v2"
        let clientID = NSTextField(string: d.string(forKey: "csc.clientID") ?? "")
        clientID.placeholderString = L("OAuth client ID")
        let secret = NSSecureTextField()
        secret.placeholderString = L("Optional")
        let port = NSTextField(string: d.string(forKey: "csc.port") ?? "8765")
        let token = NSSecureTextField()
        token.placeholderString = L("Optional: an access token instead of OAuth")
        let alert = NSAlert.form(L("Remote Signing (CSC API)"),
                                 info: L("Signs with a certificate held by a trust service provider. Only the document hash is sent; you sign in at the provider in your browser (redirect http://127.0.0.1:PORT/callback)."),
                                 ok: L("Connect"),
                                 rows: [(L("Service URL:"), url), (L("Client ID:"), clientID), (L("Client secret:"), secret),
                                        (L("Redirect port:"), port), (L("Access token:"), token)])
        guard alert.runModal() == .alertFirstButtonReturn, let base = URL(string: url.stringValue.trimmingCharacters(in: .whitespaces)) else { return nil }
        d.set(url.stringValue, forKey: "csc.url")
        d.set(clientID.stringValue, forKey: "csc.clientID")
        d.set(port.stringValue, forKey: "csc.port")
        var config = CSCClient.Config(baseURL: base)
        config.accessToken = token.stringValue.isEmpty ? nil : token.stringValue
        config.clientID = clientID.stringValue.isEmpty ? nil : clientID.stringValue
        config.clientSecret = secret.stringValue.isEmpty ? nil : secret.stringValue
        config.redirectPort = UInt16(port.stringValue) ?? 8765
        let client = CSCClient(config)
        do {
            let credentials = try client.listCredentials().filter { !$0.chain.isEmpty }
            guard !credentials.isEmpty else { throw CSCError.service(L("no credentials with certificates")) }
            var chosen = credentials[0]
            if credentials.count > 1 {
                let list = NSPopUpButton(frame: .zero, pullsDown: false)
                list.addItems(withTitles: credentials.map(\.label))
                let pick = NSAlert.form(L("Choose a Certificate"), ok: L("Choose"), rows: [(L("Certificate:"), list)])
                guard pick.runModal() == .alertFirstButtonReturn else { return nil }
                chosen = credentials[list.indexOfSelectedItem]
            }
            return CSCSigner(client: client, credential: chosen, authData: askAuthData)
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    /// PIN and/or one-time password for an explicitly authorized remote credential.
    static func askAuthData(_ credential: CSCClient.Credential) throws -> (pin: String?, otp: String?) {
        let pin = NSSecureTextField(), otp = NSTextField()
        var rows: [(String, NSView)] = []
        if credential.needsPIN || !credential.needsOTP { rows.append((L("PIN:"), pin)) }
        if credential.needsOTP { rows.append((L("One-time code:"), otp)) }
        let alert = NSAlert.form(L("Authorize Signature"), info: credential.label, ok: L("Sign"), rows: rows)
        alert.window.initialFirstResponder = rows[0].1
        guard alert.runModal() == .alertFirstButtonReturn else { throw CSCError.service(L("authorization was cancelled")) }
        return (rows.contains { $0.1 === pin } ? pin.stringValue : nil, credential.needsOTP ? otp.stringValue : nil)
    }

    static func importCertificate() -> SigningIdentity? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "p12")!, .init(filenameExtension: "pfx")!]
        panel.message = L("Choose a certificate file with a private key (.p12 / .pfx)")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return nil }
        let field = NSSecureTextField()
        let alert = NSAlert.form(L("Certificate Password"), info: url.lastPathComponent, ok: L("Import"), rows: [(L("Password:"), field)])
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            return try CertificateStore.importPKCS12(data, password: field.stringValue, toKeychain: true)
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    static func createCertificate() -> SigningIdentity? {
        let name = NSTextField(string: NSFullUserName())
        let email = NSTextField(string: "")
        email.placeholderString = "name@example.com"
        let org = NSTextField(string: "")
        org.placeholderString = L("Optional")
        let alert = NSAlert.form(L("New Signing Certificate"),
                                 info: L("A self-signed certificate valid for 5 years. Fine for internal documents; a legally binding signature needs a certificate from a certification authority."),
                                 ok: L("Create"), rows: [(L("Name:"), name), ("Email:", email), (L("Organisation:"), org)])
        guard alert.runModal() == .alertFirstButtonReturn, !name.stringValue.isEmpty else { return nil }
        do {
            return try CertificateStore.createSelfSigned(name: name.stringValue, email: email.stringValue, organization: org.stringValue)
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    static func showResults(_ signatures: [SignatureInfo], window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = signatures.isEmpty ? L("This document has no digital signatures") : L("Digital signatures: %d", signatures.count)
        alert.icon = Theme42.symbol(signatures.isEmpty ? "seal" : "checkmark.seal.fill", size: 40)
        if !signatures.isEmpty {
            let stack = NSStackView(views: signatures.enumerated().map { card($0.element, index: $0.offset + 1) })
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
        }
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private static func card(_ s: SignatureInfo, index: Int) -> NSView {
        let style: BannerView.Style = s.status == .valid ? (s.coversWholeFile ? .success : .info) : s.status == .untrusted ? .warning : .error
        let color: NSColor = style == .success ? .systemGreen : style == .info ? .systemBlue : style == .warning ? .systemOrange : .systemRed
        let symbol = style == .success ? "checkmark.seal.fill" : style == .error ? "xmark.seal.fill" : "exclamationmark.triangle.fill"
        let icon = NSImageView(image: Theme42.symbol(symbol, size: 20, weight: .semibold) ?? NSImage())
        icon.contentTintColor = color

        let title = NSTextField(labelWithString: s.email.map { "\(s.signer) · \($0)" } ?? s.signer)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        var lines = [s.summary]
        if let d = s.date { lines.append(L("Signed: %@", d.formatted(date: .long, time: .shortened))) }
        if let t = s.timestamp { lines.append(L("Trusted timestamp: %@", t.formatted(date: .long, time: .standard))) }
        if let level = s.level { lines.append(L("Format: %@", level)) }
        if let ltv = s.ltvSummary { lines.append(ltv) }
        if let r = s.reason { lines.append(L("Reason: %@", r)) }
        if let l = s.location { lines.append(L("Location: %@", l)) }
        if s.status == .untrusted, let t = s.trustMessage { lines.append(t) }
        let body = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 300

        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 10
        return row
    }
}

/// Small horizontal row of push buttons with closure actions (used inside alerts).
final class ButtonRow: NSStackView {
    private var handlers: [() -> Void] = []

    func add(_ title: String, _ handler: @escaping () -> Void) {
        let b = NSButton(title: title, target: self, action: #selector(tap(_:)))
        b.bezelStyle = .push
        b.controlSize = .small
        b.tag = handlers.count
        handlers.append(handler)
        addArrangedSubview(b)
    }

    @objc private func tap(_ sender: NSButton) { handlers[sender.tag]() }
}
