// regenerates app/Resources/AppIcon.icon/Assets/glyph.svg from the bundled display font
// run with: swift scripts/icon-glyph.swift
import CoreText
import Foundation

let fontURL = URL(fileURLWithPath: "app/Resources/Fonts/ChakraPetch-BoldItalic.ttf") as CFURL
let desc = (CTFontManagerCreateFontDescriptorsFromURL(fontURL) as! [CTFontDescriptor])[0]
let font = CTFontCreateWithFontDescriptor(desc, 620, nil)
var chars: [UniChar] = Array("A".utf16)
var glyphs = [CGGlyph](repeating: 0, count: 1)
CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
let path = CTFontCreatePathForGlyph(font, glyphs[0], nil)!
let box = path.boundingBoxOfPath
// centre on the plate (512, 512) and flip into svg's y-down space
let dx = 512 - box.midX + 12, dy = 512 + box.midY
var d = ""
path.applyWithBlock { el in
    let p = el.pointee.points
    func pt(_ i: Int) -> String { String(format: "%.1f %.1f", p[i].x + dx, dy - p[i].y) }
    switch el.pointee.type {
    case .moveToPoint: d += "M\(pt(0)) "
    case .addLineToPoint: d += "L\(pt(0)) "
    case .addQuadCurveToPoint: d += "Q\(pt(0)) \(pt(1)) "
    case .addCurveToPoint: d += "C\(pt(0)) \(pt(1)) \(pt(2)) "
    case .closeSubpath: d += "Z "
    @unknown default: break
    }
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <path fill-rule="nonzero" fill="#121214" d="\(d.trimmingCharacters(in: .whitespaces))"/>
</svg>

"""
try! svg.write(toFile: "app/Resources/AppIcon.icon/Assets/glyph.svg", atomically: true, encoding: .utf8)
print("glyph box", box)
