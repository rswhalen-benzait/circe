#!/usr/bin/env swift
import AppKit
import Foundation

// Vector artwork: a golden crescent and an orbit, on a sculpted amethyst squircle.
// Render every icon resolution directly so the small Dock sizes stay crisp.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources", isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: output, withIntermediateDirectories: true)
let iconset = output.appendingPathComponent("Circe.iconset", isDirectory: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func gradient(_ colors: [NSColor], _ locations: [CGFloat]? = nil) -> NSGradient {
    if let locations { return NSGradient(colors: colors, atLocations: locations, colorSpace: .sRGB)! }
    return NSGradient(colors: colors)!
}
func star(at point: NSPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: point.x, y: point.y + radius))
    path.curve(to: NSPoint(x: point.x + radius * 0.65, y: point.y), controlPoint1: NSPoint(x: point.x + radius * 0.13, y: point.y + radius * 0.15), controlPoint2: NSPoint(x: point.x + radius * 0.15, y: point.y + radius * 0.12))
    path.curve(to: NSPoint(x: point.x, y: point.y - radius), controlPoint1: NSPoint(x: point.x + radius * 0.15, y: point.y - radius * 0.12), controlPoint2: NSPoint(x: point.x + radius * 0.13, y: point.y - radius * 0.15))
    path.curve(to: NSPoint(x: point.x - radius * 0.65, y: point.y), controlPoint1: NSPoint(x: point.x - radius * 0.13, y: point.y - radius * 0.15), controlPoint2: NSPoint(x: point.x - radius * 0.15, y: point.y - radius * 0.12))
    path.curve(to: NSPoint(x: point.x, y: point.y + radius), controlPoint1: NSPoint(x: point.x - radius * 0.15, y: point.y + radius * 0.12), controlPoint2: NSPoint(x: point.x - radius * 0.13, y: point.y + radius * 0.15))
    path.close(); return path
}
func render(_ pixels: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let bounds = NSRect(x: 72, y: 76, width: 880, height: 880)
    let tile = NSBezierPath(roundedRect: bounds, xRadius: 194, yRadius: 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0.12, 0.06, 0.22, 0.38); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -19); shadow.set()
    color(0.23, 0.12, 0.40).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    gradient([color(0.53, 0.38, 0.76), color(0.30, 0.18, 0.50), color(0.14, 0.08, 0.28)], [0, 0.48, 1]).draw(in: tile, angle: -65)
    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    let cg = context.cgContext
    let glowColors = [color(0.84, 0.72, 1, 0.40).cgColor, color(0.55, 0.39, 0.85, 0).cgColor] as CFArray
    let topGlow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: glowColors, locations: [0, 1])!
    cg.drawRadialGradient(topGlow, startCenter: CGPoint(x: 310, y: 920), startRadius: 0, endCenter: CGPoint(x: 310, y: 920), endRadius: 770, options: [])
    let bottomColors = [color(0.46, 0.25, 0.72, 0.42).cgColor, color(0.17, 0.10, 0.30, 0).cgColor] as CFArray
    let bottomGlow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: bottomColors, locations: [0, 1])!
    cg.drawRadialGradient(bottomGlow, startCenter: CGPoint(x: 810, y: 180), startRadius: 0, endCenter: CGPoint(x: 810, y: 180), endRadius: 600, options: [])
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    let bevel = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 192, yRadius: 192)
    bevel.lineWidth = 3; color(1, 0.9, 1, 0.18).setStroke(); bevel.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The rear orbit reads as a quiet halo; the crescent remains legible at 16 px.
    let orbit = NSBezierPath(ovalIn: NSRect(x: 206, y: 350, width: 631, height: 259))
    let transform = AffineTransform(translationByX: -512, byY: -490)
    orbit.transform(using: transform)
    var rotation = AffineTransform(); rotation.rotate(byDegrees: 34); orbit.transform(using: rotation)
    orbit.transform(using: AffineTransform(translationByX: 512, byY: 490))
    orbit.lineWidth = pixels <= 32 ? 8 : 5
    color(0.93, 0.75, 0.45, 0.45).setStroke(); orbit.stroke()

    let moon = NSBezierPath()
    moon.move(to: NSPoint(x: 642, y: 766))
    moon.curve(to: NSPoint(x: 360, y: 712), controlPoint1: NSPoint(x: 549, y: 817), controlPoint2: NSPoint(x: 426, y: 786))
    moon.curve(to: NSPoint(x: 347, y: 345), controlPoint1: NSPoint(x: 249, y: 605), controlPoint2: NSPoint(x: 259, y: 447))
    moon.curve(to: NSPoint(x: 690, y: 304), controlPoint1: NSPoint(x: 433, y: 248), controlPoint2: NSPoint(x: 589, y: 239))
    moon.curve(to: NSPoint(x: 712, y: 332), controlPoint1: NSPoint(x: 709, y: 316), controlPoint2: NSPoint(x: 723, y: 331))
    moon.curve(to: NSPoint(x: 433, y: 402), controlPoint1: NSPoint(x: 605, y: 293), controlPoint2: NSPoint(x: 493, y: 331))
    moon.curve(to: NSPoint(x: 440, y: 664), controlPoint1: NSPoint(x: 369, y: 476), controlPoint2: NSPoint(x: 373, y: 590))
    moon.curve(to: NSPoint(x: 640, y: 743), controlPoint1: NSPoint(x: 495, y: 726), controlPoint2: NSPoint(x: 566, y: 746))
    moon.curve(to: NSPoint(x: 642, y: 766), controlPoint1: NSPoint(x: 658, y: 744), controlPoint2: NSPoint(x: 660, y: 757))
    moon.close()
    NSGraphicsContext.saveGraphicsState()
    let moonShadow = NSShadow(); moonShadow.shadowColor = color(0.08, 0.02, 0.18, 0.45); moonShadow.shadowBlurRadius = 19; moonShadow.shadowOffset = NSSize(width: 0, height: -9); moonShadow.set()
    color(0.86, 0.64, 0.32).setFill(); moon.fill()
    NSGraphicsContext.restoreGraphicsState()
    gradient([color(1, 0.94, 0.76), color(0.98, 0.81, 0.50), color(0.69, 0.43, 0.20)], [0, 0.51, 1]).draw(in: moon, angle: -87)
    moon.lineWidth = 2; color(1, 0.94, 0.79, 0.6).setStroke(); moon.stroke()
    let light = star(at: NSPoint(x: 685, y: 659), radius: 91)
    NSGraphicsContext.saveGraphicsState()
    let shine = NSShadow(); shine.shadowColor = color(1, 0.77, 0.42, 0.35); shine.shadowBlurRadius = 30; shine.set()
    color(1, 0.87, 0.60).setFill(); light.fill()
    NSGraphicsContext.restoreGraphicsState()
    gradient([color(1, 0.98, 0.85), color(0.96, 0.75, 0.41)]).draw(in: light, angle: -90)
    if pixels > 32 {
        color(1, 0.91, 0.73, 0.8).setFill(); star(at: NSPoint(x: 746, y: 473), radius: 21).fill()
        color(0.97, 0.87, 0.70, 0.6).setFill(); NSBezierPath(ovalIn: NSRect(x: 275, y: 584, width: 7, height: 7)).fill()
    }
    context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
    return bitmap
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let bitmap = render(points * scale)
        let suffix = scale == 2 ? "@2x" : ""
        let path = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }
}
try render(1024).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("Circe.png"))
let iconutil = Process(); iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", output.appendingPathComponent("Circe.icns").path, iconset.path]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
try fm.removeItem(at: iconset)
print("Generated \(output.appendingPathComponent("Circe.icns").path)")
