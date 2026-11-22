// deadzone.swift — black out a damaged strip of the built-in MacBook screen
// and keep the mouse pointer out of it.
//
// Run in Terminal:   swift deadzone.swift 0.30 left
//   1st value = fraction of the screen width to black out (0.30 = 30%)
//   2nd value = which side is damaged: left or right
// Stop it with Ctrl+C in that Terminal window.

import Cocoa

let args = CommandLine.arguments
let fraction = CGFloat(Double(args.count > 1 ? args[1] : "0.3") ?? 0.3)
let side = args.count > 2 ? args[2].lowercased() : "left"

// Use the built-in display
let screen = NSScreen.screens.first { s in
    let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    return CGDisplayIsBuiltin(id) != 0
} ?? NSScreen.screens[0]

let f = screen.frame
let deadW = (f.width * fraction).rounded()
let deadRect = side == "right"
    ? NSRect(x: f.maxX - deadW, y: f.minY, width: deadW, height: f.height)
    : NSRect(x: f.minX, y: f.minY, width: deadW, height: f.height)
let usableMinX = side == "right" ? f.minX : f.minX + deadW
let usableMaxX = side == "right" ? f.maxX - deadW - 1 : f.maxX - 1

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon

// Black window that sits above everything, on every Space and over full-screen apps
let win = NSWindow(contentRect: deadRect, styleMask: .borderless, backing: .buffered, defer: false)
win.backgroundColor = .black
win.isOpaque = true
win.hasShadow = false
win.level = .screenSaver
win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
win.orderFrontRegardless()

// Keep the pointer inside the usable area
let primaryHeight = NSScreen.screens[0].frame.height
Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { _ in
    let p = NSEvent.mouseLocation
    guard p.y >= f.minY, p.y <= f.maxY else { return }
    if p.x < usableMinX || p.x > usableMaxX {
        let x = min(max(p.x, usableMinX), usableMaxX)
        CGWarpMouseCursorPosition(CGPoint(x: x, y: primaryHeight - p.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

print("Blacking out \(Int(fraction * 100))% on the \(side). Press Ctrl+C to stop.")
app.run()
