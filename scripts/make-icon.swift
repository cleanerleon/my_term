import AppKit
import Foundation
let output = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let s = CGFloat(size)
        NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.90, height: s * 0.90), xRadius: s * 0.20, yRadius: s * 0.20).fill()
        NSColor(calibratedRed: 0.35, green: 0.9, blue: 0.73, alpha: 1).setStroke()
        let prompt = NSBezierPath(); prompt.lineWidth = s * 0.065; prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round
        prompt.move(to: NSPoint(x: s * 0.27, y: s * 0.64)); prompt.line(to: NSPoint(x: s * 0.44, y: s * 0.48)); prompt.line(to: NSPoint(x: s * 0.27, y: s * 0.32)); prompt.stroke()
        let cursor = NSBezierPath(); cursor.lineWidth = s * 0.065; cursor.lineCapStyle = .round
        cursor.move(to: NSPoint(x: s * 0.54, y: s * 0.32)); cursor.line(to: NSPoint(x: s * 0.73, y: s * 0.32)); cursor.stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(filename))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
