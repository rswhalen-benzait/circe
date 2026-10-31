#!/usr/bin/env swift
import AppKit
import Foundation

// Match Circe's warm paper, amethyst, serif typography, and quiet celestial motif.
// Finder receives a combined 1x/2x TIFF from dmgbuild; no fixed-resolution text.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/dmg-artwork", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func font(_ size: CGFloat, serif: Bool = false, weight: NSFont.Weight = .regular) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return serif ? NSFont(descriptor: base.fontDescriptor.withDesign(.serif)!, size: size)! : base
}
func drawText(_ text: String, top: CGFloat, size: CGFloat, serif: Bool = false, ink: UInt32 = 0x242038, weight: NSFont.Weight = .regular) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    (text as NSString).draw(in: NSRect(x: 50, y: 480 - top - size * 1.5, width: 620, height: size * 1.8),
                           withAttributes: [.font: font(size, serif: serif, weight: weight), .foregroundColor: color(ink), .paragraphStyle: paragraph])
}
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720 * scale, pixelsHigh: 480 * scale,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: 720, height: 480)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    color(0xFAF8F4).setFill(); NSRect(x: 0, y: 0, width: 720, height: 480).fill()
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xE7DCF4, alpha: 0.85).cgColor, color(0xFAF8F4, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    context.cgContext.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 500), startRadius: 0,
                                         endCenter: CGPoint(x: 360, y: 500), endRadius: 390, options: [])
    // A crescent, with the opening toward the direction of installation.
    let crescent = NSBezierPath()
    crescent.appendArc(withCenter: NSPoint(x: 360, y: 417), radius: 15, startAngle: 40, endAngle: 320)
    crescent.lineWidth = 2; crescent.lineCapStyle = .round; color(0x876636).setStroke(); crescent.stroke()
    let sparkle = NSBezierPath()
    sparkle.move(to: NSPoint(x: 375, y: 433)); sparkle.line(to: NSPoint(x: 375, y: 423))
    sparkle.move(to: NSPoint(x: 370, y: 428)); sparkle.line(to: NSPoint(x: 380, y: 428))
    sparkle.lineWidth = 1.5; sparkle.lineCapStyle = .round; sparkle.stroke()
    drawText("Welcome to Circe.", top: 92, size: 33, serif: true)
    drawText("Your Mac. Wherever you are.", top: 144, size: 13, ink: 0x625B70)
    // Icons occupy the open space centered at y=270 in Finder's top-left coordinates.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 315, y: 210)); arrow.line(to: NSPoint(x: 405, y: 210))
    arrow.move(to: NSPoint(x: 395, y: 220)); arrow.line(to: NSPoint(x: 405, y: 210)); arrow.line(to: NSPoint(x: 395, y: 200))
    arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    color(0x8D819B).setStroke(); arrow.stroke()
    drawText("Drag Circe to Applications to begin.", top: 377, size: 14, ink: 0x625B70)
    drawText("Connect to your Macs. Or make this one available.", top: 413, size: 11, ink: 0x625B70)
    context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("background\(suffix).png"))
}
print("Generated Retina disk image background in \(output.path)")
