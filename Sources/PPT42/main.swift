import AppKit
import Kit42

Localization.register(rows: ppt42Strings)

// Command-line checks (no UI): --info, --export, --convert, --demo. See CLI.swift.
if CLI.run(CommandLine.arguments) { exit(CLI.status) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.run()
