import AppKit

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--icons" {
    for powered in [false, true] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 4, y: 4)
        NSColor.black.setStroke()
        let monitor = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 5.5, width: 21, height: 13), xRadius: 1.7, yRadius: 1.7)
        monitor.lineWidth = 1.6
        monitor.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 12, y: 5.5)); stand.line(to: NSPoint(x: 12, y: 2))
        stand.move(to: NSPoint(x: 8, y: 2)); stand.line(to: NSPoint(x: 16, y: 2))
        stand.lineWidth = 1.6; stand.lineCapStyle = .round; stand.stroke()
        if powered {
            let power = NSBezierPath()
            power.appendArc(withCenter: NSPoint(x: 12, y: 12), radius: 3, startAngle: 135, endAngle: 45, clockwise: false)
            power.move(to: NSPoint(x: 12, y: 15.7)); power.line(to: NSPoint(x: 12, y: 11.8))
            power.lineWidth = 1.3; power.lineCapStyle = .round; power.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let url = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(powered ? "menu-on.png" : "menu-off.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
    exit(0)
}

// SwiftBar opens a local app through LaunchServices. No AppleScript,
// Accessibility permission or control of other applications is needed.
final class ActionDelegate: NSObject, NSApplicationDelegate {
    var task: Process?
    var panel: NSPanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let executable = info["ActionCommand"] as? String,
              var arguments = info["ActionArguments"] as? [String],
              let title = info["ActionTitle"] as? String else { NSApp.terminate(nil); return }
        if let confirmation = info["ActionConfirmation"] as? String {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = confirmation
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
        }
        if let direction = info["PortDirection"] as? String {
            let opposite = direction == "host" ? "guest" : "host"
            let alert = NSAlert()
            alert.messageText = "Forward a \(direction) port"
            alert.informativeText = "Enter \(direction) service port:\(opposite) access port. Both use localhost."
            let input = NSTextField(string: "8080:8080")
            input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = input
            alert.addButton(withTitle: "Forward")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
            let ports = input.stringValue.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(ports.count), let from = Int(ports[0]),
                  let to = Int(ports.count == 2 ? ports[1] : ports[0]),
                  (1...65535).contains(from), (1024...65535).contains(to) else {
                showError("Enter a service port from 1–65535 and an access port from 1024–65535.", log: nil)
                return
            }
            arguments.removeLast()
            arguments.append(contentsOf: ["add-port", direction, String(from), String(to)])
        }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 86),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Agent VM"
        let label = NSTextField(labelWithString: title + "…")
        label.frame = NSRect(x: 56, y: 30, width: 270, height: 22)
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 28, width: 24, height: 24))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(spinner)
        window.center()
        window.makeKeyAndOrderFront(nil)
        panel = window
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                self.panel?.close()
                if finished.terminationStatus == 0 { NSApp.terminate(nil) }
                else { self.showError("The VM action failed. Open its log for details.", log: info["ActionLog"] as? String) }
            }
        }
        do { try process.run(); task = process }
        catch { showError("Could not start the VM command.", log: nil) }
    }
    func showError(_ text: String, log: String?) {
        panel?.close()
        let alert = NSAlert()
        alert.messageText = "VM action failed"
        alert.informativeText = text
        alert.addButton(withTitle: log == nil ? "OK" : "Open Log")
        if log != nil { alert.addButton(withTitle: "Close") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let log {
            NSWorkspace.shared.open(URL(fileURLWithPath: log))
        }
        NSApp.terminate(nil)
    }
}
let app = NSApplication.shared
let delegate = ActionDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
