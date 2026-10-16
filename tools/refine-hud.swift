// refine-hud: a tiny floating pill that shows progress without stealing focus.
//
//   refine-hud "Refining…"                 spinner + label until the process is killed (max 90s)
//   refine-hud --flash "✓ Refined" [secs]  label only, closes itself (default 1.2s)
//
// Build: swiftc -O -o refine-hud refine-hud.swift
import Cocoa

let args = CommandLine.arguments
var label = "Refining…"
var flashSeconds: Double? = nil
if args.count > 1 {
    if args[1] == "--flash" {
        label = args.count > 2 ? args[2] : ""
        flashSeconds = args.count > 3 ? (Double(args[3]) ?? 1.2) : 1.2
    } else {
        label = args[1]
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, never becomes the active app

let font = NSFont.systemFont(ofSize: 14, weight: .medium)
let textSize = (label as NSString).size(withAttributes: [.font: font])
let showSpinner = flashSeconds == nil
let padding: CGFloat = 16
let spinnerSize: CGFloat = 16
let gap: CGFloat = 8
let height: CGFloat = 40
let width = padding * 2 + ceil(textSize.width) + (showSpinner ? spinnerSize + gap : 0)

let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
let frame = NSRect(x: area.midX - width / 2, y: area.minY + 64, width: width, height: height)

let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.level = .statusBar
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.ignoresMouseEvents = true
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
blur.material = .hudWindow
blur.state = .active
blur.wantsLayer = true
blur.layer?.cornerRadius = height / 2
blur.layer?.masksToBounds = true
panel.contentView = blur

var x = padding
if showSpinner {
    let spinner = NSProgressIndicator(frame: NSRect(x: padding, y: (height - spinnerSize) / 2,
                                                    width: spinnerSize, height: spinnerSize))
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.startAnimation(nil)
    blur.addSubview(spinner)
    x += spinnerSize + gap
}
let field = NSTextField(labelWithString: label)
field.font = font
field.textColor = .labelColor
field.frame = NSRect(x: x, y: (height - ceil(textSize.height)) / 2,
                     width: ceil(textSize.width) + 2, height: ceil(textSize.height))
blur.addSubview(field)

panel.orderFrontRegardless()

// SIGTERM (sent by the scripts when the work is done) terminates us by default.
DispatchQueue.main.asyncAfter(deadline: .now() + (flashSeconds ?? 90)) { exit(0) }
app.run()
