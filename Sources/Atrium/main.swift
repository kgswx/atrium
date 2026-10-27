import AppKit

// Command-line switches used by the install script, then exit without showing anything.
let arguments = CommandLine.arguments
if arguments.contains("--make-default") || arguments.contains("--restore-finder") {
    let on = arguments.contains("--make-default")
    DefaultViewer.set(on)
    print(on ? "“Show in Finder” in other apps now opens Atrium." : "“Show in Finder” opens Finder again.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
