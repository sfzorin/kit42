import AppKit
import Kit42

Localization.register(rows: scn42Strings)

// Command-line checks (no UI): --process, --pipeline, --detect-photos, --fake-scan, --list-devices. See CLI.swift.
if CLI.run(CommandLine.arguments) { exit(CLI.status) }
