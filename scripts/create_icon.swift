#!/usr/bin/env swift
import AppKit
import Foundation

// Original vector artwork. All bitmap sizes are rendered from this drawing;
// there are no downloaded assets or external image-generation dependencies.
func render(size: Int) throws -> Data {
    let scale = CGFloat(size) / 1024
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "ClickyIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.scaleBy(x: scale, y: scale)
    context.cgContext.setShouldAntialias(true)

    let frame = NSRect(x: 55, y: 55, width: 914, height: 914)
    let background = NSBezierPath(roundedRect: frame, xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.19, blue: 0.18, alpha: 1),
               ending: NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1))!
        .draw(in: background, angle: -90)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 42
    shadow.shadowOffset = NSSize(width: 0, height: -21)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let base = NSBezierPath(roundedRect: NSRect(x: 211, y: 192, width: 602, height: 588), xRadius: 112, yRadius: 112)
    NSColor(calibratedRed: 0.50, green: 0.24, blue: 0.09, alpha: 1).setFill()
    base.fill()
    NSGraphicsContext.restoreGraphicsState()

    let face = NSBezierPath(roundedRect: NSRect(x: 211, y: 246, width: 602, height: 565), xRadius: 110, yRadius: 110)
    NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.37, alpha: 1),
               ending: NSColor(calibratedRed: 0.90, green: 0.45, blue: 0.16, alpha: 1))!
        .draw(in: face, angle: -90)
    NSColor.white.withAlphaComponent(0.30).setStroke()
    let inset = NSBezierPath(roundedRect: NSRect(x: 227, y: 266, width: 570, height: 527), xRadius: 96, yRadius: 96)
    inset.lineWidth = 3
    inset.stroke()

    let font = NSFont.systemFont(ofSize: 340, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font,
        .foregroundColor: NSColor(calibratedRed: 0.24, green: 0.13, blue: 0.08, alpha: 1)]
    let text = NSAttributedString(string: "C", attributes: attributes)
    let textSize = text.size()
    text.draw(at: NSPoint(x: 512 - textSize.width / 2 - 3, y: 515 - textSize.height / 2 + 8))
    NSColor.white.withAlphaComponent(0.72).setFill()
    NSBezierPath(roundedRect: NSRect(x: 659, y: 713, width: 60, height: 14), xRadius: 7, yRadius: 7).fill()
    context.flushGraphics()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ClickyIcon", code: 2)
    }
    return data
}

do {
    let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/AppIcon.icns")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Clicky-Icon-\(UUID().uuidString)")
    let iconset = temporary.appendingPathComponent("Clicky.iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    for base in [16, 32, 128, 256, 512] {
        try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "ClickyIcon", code: Int(process.terminationStatus)) }
    print("Created original Clicky icon: \(destination.path)")
} catch {
    fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
