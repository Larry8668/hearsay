import AppKit

// macOS icon: 1024 canvas, 824 pt rounded tile (Apple's template margins), waveform on top.
let canvas: CGFloat = 1024
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 824 * 0.2237

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    ctx.cgContext.setAllowsAntialiasing(true)
    ctx.cgContext.interpolationQuality = .high

    // Shadow under the tile (Apple icons have a soft one).
    let shadow = NSShadow(); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).setFill(); path.fill()
    NSShadow().set()

    // Dark graphite gradient with a faint top highlight.
    let grad = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.25, alpha: 1), 0),
        (NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 1), 0.55),
        (NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1), 1))!
    grad.draw(in: path, angle: -90)
    NSColor.white.withAlphaComponent(0.06).setStroke(); path.lineWidth = 6; path.addClip(); path.stroke()
    ctx.cgContext.resetClip()

    // The bars: the "waveform" symbol's rhythm, left half "me" (blue), right half "them" (orange),
    // blended through the middle: two voices in one picture.
    let heights: [CGFloat] = [0.22, 0.42, 0.68, 0.90, 0.56, 0.34, 0.74, 1.0, 0.62, 0.40, 0.80, 0.52, 0.28]
    let n = heights.count
    let barW: CGFloat = 34, gap: CGFloat = 22
    let totalW = CGFloat(n) * barW + CGFloat(n - 1) * gap
    let x0 = (canvas - totalW) / 2, midY = canvas / 2, maxH: CGFloat = 480
    let me = NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1)
    let them = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.30, alpha: 1)
    for (i, h) in heights.enumerated() {
        let t = CGFloat(i) / CGFloat(n - 1)
        let mix = min(max((t - 0.35) / 0.3, 0), 1)   // blue until 35%, orange after 65%
        let c = me.blended(withFraction: mix, of: them)!
        let bh = maxH * h
        let r = NSRect(x: x0 + CGFloat(i) * (barW + gap), y: midY - bh / 2, width: barW, height: bh)
        let bar = NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2)
        let glow = NSShadow(); glow.shadowBlurRadius = 18; glow.shadowOffset = .zero
        glow.shadowColor = c.withAlphaComponent(0.45); glow.set()
        c.setFill(); bar.fill()
        NSShadow().set()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
let sizes: [(Int, String)] = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
                              (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
for (px, name) in sizes {
    let data = render(px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/AppIcon.iconset/icon_\(name).png"))
}
try! render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon-1024.png"))
try! render(256).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon-256.png"))
print("ok")
