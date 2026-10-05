import AppKit

// Showing/hiding our own Tart app uses normal application activation, not
// Accessibility or Apple Events controlling Terminal, Finder, or other apps.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

func waitFor(_ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while !predicate() && Date() < deadline {
        // NSRunningApplication caches mutable state until the run loop turns.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return predicate()
}

guard CommandLine.arguments.count == 3,
      let pid = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid),
      !app.isTerminated else {
    fputs("The VM window process is unavailable.\n", stderr)
    exit(1)
}
switch CommandLine.arguments[2] {
case "show":
    app.unhide()
    guard app.activate(options: [.activateAllWindows]) || app.isActive else {
        fputs("Could not bring the VM window forward.\n", stderr)
        exit(1)
    }
case "hide":
    guard app.activationPolicy == .regular else {
        fputs("The native window is still starting.\n", stderr)
        exit(1)
    }
    _ = app.hide()
    guard waitFor({ app.isHidden }) else {
        fputs("Could not hide the VM window (activation policy \(app.activationPolicy.rawValue)).\n", stderr)
        exit(1)
    }
case "status":
    print(app.isHidden ? "hidden" : "visible")
default:
    fputs("Expected show, hide, or status.\n", stderr)
    exit(1)
}
