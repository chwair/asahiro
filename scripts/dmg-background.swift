// renders the dmg window background at 1x and 2x into app/Resources/dmg/
// run from the repo root: swift scripts/dmg-background.swift
import AppKit
import CoreText

let width: CGFloat = 660
let height: CGFloat = 420
// icon centres in finder coordinates (origin top left), kept in sync with build-dmg.sh
let appPoint = CGPoint(x: 170, y: 175)
let linkPoint = CGPoint(x: 490, y: 175)

let yellow = NSColor(calibratedRed: 0.98, green: 0.86, blue: 0.0, alpha: 1)
let ink = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)

func registerFonts() {
    for name in ["ChakraPetch-BoldItalic", "ChakraPetch-SemiBold", "ChakraPetch-Medium"] {
        let url = URL(fileURLWithPath: "app/Resources/Fonts/\(name).ttf") as CFURL
        CTFontManagerRegisterFontsForURL(url, .process, nil)
    }
}

extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

func chamfer(_ r: CGRect, cut: CGFloat) -> NSBezierPath {
    // y is flipped in the context, so "top left" here is visually top left
    let p = NSBezierPath()
    p.move(to: CGPoint(x: r.minX + cut, y: r.minY))
    p.line(to: CGPoint(x: r.maxX, y: r.minY))
    p.line(to: CGPoint(x: r.maxX, y: r.maxY - cut))
    p.line(to: CGPoint(x: r.maxX - cut, y: r.maxY))
    p.line(to: CGPoint(x: r.minX, y: r.maxY))
    p.line(to: CGPoint(x: r.minX, y: r.minY + cut))
    p.close()
    return p
}

func text(_ s: String, font: String, size: CGFloat, color: NSColor, at p: CGPoint, kern: CGFloat = 0, center: Bool = false) {
    let f = NSFont(name: font, size: size) ?? .systemFont(ofSize: size, weight: .bold)
    let str = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .kern: kern])
    let sz = str.size()
    str.draw(at: CGPoint(x: center ? p.x - sz.width / 2 : p.x, y: p.y))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    // flip so drawing coordinates match finder's top-left origin
    cg.translateBy(x: 0, y: height)
    cg.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.current = flipped

    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.115, alpha: 1),
                        NSColor(calibratedRed: 0.045, green: 0.047, blue: 0.055, alpha: 1)])!
        .draw(in: bounds, angle: 90)

    // faint diagonal grain across the whole window
    NSColor.white.withAlphaComponent(0.025).setStroke()
    let grain = NSBezierPath()
    grain.lineWidth = 1
    var x: CGFloat = -height
    while x < width {
        grain.move(to: CGPoint(x: x, y: height))
        grain.line(to: CGPoint(x: x + height, y: 0))
        x += 14
    }
    grain.stroke()

    // arrow from the app to applications: a chamfered bar with a stepped head
    let mid = CGPoint(x: (appPoint.x + linkPoint.x) / 2, y: appPoint.y)
    let bar = CGRect(x: mid.x - 58, y: mid.y - 7, width: 84, height: 14)
    chamfer(bar, cut: 5).fill(with: yellow)
    let head = NSBezierPath()
    head.move(to: CGPoint(x: bar.maxX - 2, y: mid.y - 20))
    head.line(to: CGPoint(x: bar.maxX + 24, y: mid.y))
    head.line(to: CGPoint(x: bar.maxX - 2, y: mid.y + 20))
    head.close()
    yellow.setFill()
    head.fill()
    // ghost chevrons trailing the arrow
    for (i, alpha) in [0.35, 0.18].enumerated() {
        let off = CGFloat(i + 1) * 16
        let chev = NSBezierPath()
        chev.lineWidth = 4
        chev.move(to: CGPoint(x: bar.minX - off, y: mid.y - 9))
        chev.line(to: CGPoint(x: bar.minX - off + 9, y: mid.y))
        chev.line(to: CGPoint(x: bar.minX - off, y: mid.y + 9))
        yellow.withAlphaComponent(alpha).setStroke()
        chev.stroke()
    }

    // mid grey tags under the icon labels: finder draws labels white in dark mode and black in light
    // mode, this grey keeps both readable
    for p in [appPoint, linkPoint] {
        let tag = CGRect(x: p.x - 60, y: p.y + 66, width: 120, height: 24)
        chamfer(tag, cut: 6).fill(with: NSColor(calibratedWhite: 0.47, alpha: 1))
    }

    // instruction
    text("Drag Asahiro into Applications to install", font: "ChakraPetch-Medium", size: 13,
         color: NSColor.white.withAlphaComponent(0.6), at: CGPoint(x: width / 2, y: 312), center: true)
    // hazard band along the top edge, the bottom can be covered by finder's path bar
    let band = CGRect(x: 0, y: 0, width: width, height: 8)
    yellow.setFill()
    band.fill()
    ink.withAlphaComponent(0.85).setFill()
    var sx: CGFloat = -12
    while sx < width {
        let stripe = NSBezierPath()
        stripe.move(to: CGPoint(x: sx, y: band.maxY))
        stripe.line(to: CGPoint(x: sx + 8, y: band.maxY))
        stripe.line(to: CGPoint(x: sx + 16, y: band.minY))
        stripe.line(to: CGPoint(x: sx + 8, y: band.minY))
        stripe.close()
        stripe.fill()
        sx += 16
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

registerFonts()
let out = URL(fileURLWithPath: "app/Resources/dmg")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let data = render(scale: scale).representation(using: .png, properties: [:])!
    try! data.write(to: out.appendingPathComponent(name))
}
print("wrote \(out.path)")
