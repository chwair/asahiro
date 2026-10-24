import SwiftUI

extension Color {
    static let zzzYellow = Color(red: 0.98, green: 0.86, blue: 0.0)
    static let zzzInk = Color(red: 0.07, green: 0.07, blue: 0.08)
    // the dark panel colour the official launcher art is painted on
    static let zzzPanel = Color(red: 14 / 255, green: 18 / 255, blue: 17 / 255)
}

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let edge: CGFloat = 32
}

enum Radius {
    static let control: CGFloat = 7
    static let group: CGFloat = 10
    static let panel: CGFloat = 22
}

// short springs with a touch of overshoot, nothing should take longer than a quarter second
enum Motion {
    static let snap = Animation.snappy(duration: 0.22, extraBounce: 0.08)
    static let quick = Animation.easeOut(duration: 0.12)
    static let press = Animation.easeOut(duration: 0.08)
}

// chakra petch is bundled under Resources/Fonts and registered through ATSApplicationFontsPath
extension Font {
    static func display(_ size: CGFloat, italic: Bool = true) -> Font {
        .custom(italic ? "ChakraPetch-BoldItalic" : "ChakraPetch-Bold", size: size)
    }

    static func displayMedium(_ size: CGFloat) -> Font {
        .custom("ChakraPetch-SemiBold", size: size)
    }
}

// rectangle with two clipped corners, a nod to the in-game ui
struct ChamferShape: Shape {
    var cut: CGFloat = 12
    var leading = true
    var trailing = true

    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = leading ? cut : 0
        let b = trailing ? cut : 0
        p.move(to: CGPoint(x: r.minX + a, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - b))
        p.addLine(to: CGPoint(x: r.maxX - b, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + a))
        p.closeSubpath()
        return p
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

// diagonal hazard stripes used for progress fills
struct Stripes: Shape {
    var spacing: CGFloat = 10
    var phase: CGFloat = 0

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = spacing / 2
        var x = -r.height - spacing + phase.truncatingRemainder(dividingBy: spacing)
        while x < r.maxX + r.height {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + w, y: r.maxY))
            p.addLine(to: CGPoint(x: x + w + r.height, y: r.minY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            p.closeSubpath()
            x += spacing
        }
        return p
    }
}
