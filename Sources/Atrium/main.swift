import AppKit

// Command-line switches used by the install script, then exit without showing anything.
let arguments = CommandLine.arguments
if arguments.contains("--make-default") || arguments.contains("--restore-finder") {
    let on = arguments.contains("--make-default")
    var finished = false
    DefaultViewer.set(on) { error in
        if let error { FileHandle.standardError.write("Atrium: \(error.localizedDescription)\n".data(using: .utf8)!) }
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    print(on ? "Atrium is now the file viewer for folders and Show in Finder." : "Finder is the file viewer again.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
