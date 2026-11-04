import AppKit
import CryptoKit
import Kit42

extension SheetProtection {
    /// Excel's legacy 16-bit password hash (`<sheetProtection password="CC1A"/>`).
    static func legacyHash(_ password: String) -> String {
        var hash: UInt32 = 0
        let bytes = Array(password.utf16.map { UInt32($0) }.prefix(15))
        for (i, c) in bytes.enumerated() {
            let v = c << UInt32(i + 1)
            hash ^= (v & 0x7FFF) | (v >> 15)
        }
        hash ^= UInt32(bytes.count)
        hash ^= 0xCE4B
        return String(format: "%04X", hash & 0xFFFF)
    }

    /// ODF `table:protection-key`: base64 SHA-256 (or legacy SHA-1) of the UTF-8 password.
    static func odsKey(_ password: String, digest: String?) -> String {
        if digest?.contains("sha1") == true { return Data(Insecure.SHA1.hash(data: Data(password.utf8))).base64EncodedString() }
        return ODS.protectionKey(password)
    }

    /// Excel 2010+ hash: SHA-512 of salt + UTF-16LE password, re-hashed `spinCount` times with the iteration number.
    static func sha512(_ password: String, salt: Data, spinCount: Int) -> String {
        var data = salt
        for u in password.utf16 { data.append(UInt8(u & 0xFF)); data.append(UInt8(u >> 8)) }
        var hash = Data(SHA512.hash(data: data))
        for i in 0..<UInt32(max(0, min(spinCount, 10_000_000))) {
            var block = hash
            withUnsafeBytes(of: i.littleEndian) { block.append(contentsOf: $0) }
            hash = Data(SHA512.hash(data: block))
        }
        return hash.base64EncodedString()
    }

    init(password: String) {
        passwordHash = password.isEmpty ? nil : Self.legacyHash(password)
        odsKey = password.isEmpty ? nil : ODS.protectionKey(password)
        odsDigest = password.isEmpty ? nil : ODS.sha256Digest
    }

    /// Whether `password` unprotects the sheet (no password set → always).
    func matches(_ password: String) -> Bool {
        if let h = sha512Hash, let salt = sha512Salt.flatMap({ Data(base64Encoded: $0) }) {
            return Self.sha512(password, salt: salt, spinCount: spinCount) == h
        }
        if let h = passwordHash { return Self.legacyHash(password) == h.uppercased() }
        if let k = odsKey { return Self.odsKey(password, digest: odsDigest) == k }
        return true
    }
}

extension SheetWindowController {
    /// Data › Protect Sheet… / Unprotect Sheet…
    @objc func protectSheetAction(_ sender: Any?) {
        guard doc != nil else { return }
        grid.commitEdit(move: nil)
        if let p = sheet.protection {
            var password = ""
            if p.passwordHash != nil || p.odsKey != nil {
                let field = NSSecureTextField(string: "")
                let alert = NSAlert.form(L("Unprotect Sheet"), ok: L("Unprotect"), rows: [(L("Password:"), field)])
                alert.window.initialFirstResponder = field
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                password = field.stringValue
            }
            guard unprotectSheet(password: password) else {
                let a = NSAlert()
                a.messageText = L("The password is incorrect.")
                a.runModal()
                return
            }
            return
        }
        let pass = NSSecureTextField(string: ""), confirm = NSSecureTextField(string: "")
        let alert = NSAlert.form(L("Protect Sheet"), info: L("Locked cells can’t be changed while the sheet is protected. Unlock cells first with Format › Protection › Locked."),
                                 ok: L("Protect"), rows: [(L("Password (optional):"), pass), (L("Confirm password:"), confirm)])
        alert.window.initialFirstResponder = pass
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard pass.stringValue == confirm.stringValue else {
            let a = NSAlert()
            a.messageText = L("The passwords don’t match.")
            a.runModal()
            return
        }
        protectSheet(password: pass.stringValue)
    }

    func protectSheet(password: String) {
        doc?.change(L("Protect Sheet"), recalc: false) { $0.sheets[sheetIndex].protection = SheetProtection(password: password) }
    }

    @discardableResult
    func unprotectSheet(password: String) -> Bool {
        guard let p = sheet.protection, p.matches(password) else { return false }
        doc?.change(L("Unprotect Sheet"), recalc: false) { $0.sheets[sheetIndex].protection = nil }
        return true
    }

    /// Format › Protection › Locked: toggles the Locked flag of the selected cells.
    @objc func toggleLockedAction(_ sender: Any?) {
        guard guardEditable(nil) else { return }
        let locked = !sheet[grid.active].style.locked
        let range = clampedSelection
        doc?.change(L("Locked"), recalc: false) { wb in
            for ref in range.cells {
                var cell = wb.sheets[sheetIndex][ref]
                cell.style.locked = locked
                wb.sheets[sheetIndex][ref] = cell
            }
        }
    }

    /// Whether `range` may be changed (nil: any structural change to the sheet). Refuses with a message.
    func guardEditable(_ range: CellRange?) -> Bool {
        guard sheet.isProtected else { return true }
        if let range {
            // Missing cells have the default (locked) style, so count unlocked cells inside the range.
            let unlocked = sheet.cells.filter { range.contains($0.key) && !$0.value.style.locked }.count
            if unlocked == range.count { return true }
        }
        refuseProtected()
        return false
    }

    func refuseProtected() {
        let text = L("The cell or chart you’re trying to change is on a protected sheet. To make a change, unprotect the sheet (Data › Unprotect Sheet…).")
        lastAlertMessage = text
        guard !suppressAlerts, let window, window.attachedSheet == nil else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L("The sheet is protected")
        alert.informativeText = text
        alert.beginSheetModal(for: window)
    }
}
