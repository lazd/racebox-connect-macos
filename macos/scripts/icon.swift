import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift icon.swift output.iconset") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon context") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    let navy = NSColor(srgbRed: 0.07, green: 0.17, blue: 0.22, alpha: 1)
    let teal = NSColor(srgbRed: 0.24, green: 0.79, blue: 0.67, alpha: 1)
    let peach = NSColor(srgbRed: 1, green: 0.66, blue: 0.45, alpha: 1)
    let outer = NSRect(x: 48, y: 48, width: 928, height: 928)
    let background = NSBezierPath(roundedRect: outer, xRadius: 210, yRadius: 210)
    let gradient = NSGradient(starting: navy, ending: NSColor(srgbRed: 0.13, green: 0.31, blue: 0.35, alpha: 1))!
    gradient.draw(in: background, angle: 65)

    // A tiny smiling telemetry box with a racing stripe, Wi-Fi halo, and ribbon bow.
    let halo = NSBezierPath()
    halo.appendArc(withCenter: NSPoint(x: 512, y: 620), radius: 220, startAngle: 40, endAngle: 140)
    halo.lineWidth = 28
    halo.lineCapStyle = .round
    teal.withAlphaComponent(0.65).setStroke()
    halo.stroke()
    let innerHalo = NSBezierPath()
    innerHalo.appendArc(withCenter: NSPoint(x: 512, y: 620), radius: 145, startAngle: 44, endAngle: 136)
    innerHalo.lineWidth = 28
    innerHalo.lineCapStyle = .round
    teal.setStroke()
    innerHalo.stroke()
    rounded(NSRect(x: 498, y: 690, width: 28, height: 28), radius: 14, color: teal)
    rounded(NSRect(x: 246, y: 235, width: 548, height: 420), radius: 110,
            color: NSColor.black.withAlphaComponent(0.18))
    rounded(NSRect(x: 230, y: 260, width: 548, height: 420), radius: 110, color: teal)
    rounded(NSRect(x: 230, y: 290, width: 548, height: 365), radius: 100,
            color: NSColor(srgbRed: 0.36, green: 0.87, blue: 0.75, alpha: 1))
    let pink = NSColor(srgbRed: 0.98, green: 0.40, blue: 0.56, alpha: 1)
    let darkPink = NSColor(srgbRed: 0.82, green: 0.22, blue: 0.39, alpha: 1)
    let tails = NSBezierPath()
    tails.move(to: NSPoint(x: 716, y: 658))
    tails.line(to: NSPoint(x: 662, y: 570))
    tails.line(to: NSPoint(x: 703, y: 580))
    tails.line(to: NSPoint(x: 722, y: 558))
    tails.line(to: NSPoint(x: 736, y: 640))
    tails.line(to: NSPoint(x: 788, y: 567))
    tails.line(to: NSPoint(x: 800, y: 599))
    tails.line(to: NSPoint(x: 836, y: 606))
    tails.line(to: NSPoint(x: 736, y: 674))
    tails.close()
    darkPink.setFill()
    tails.fill()
    let bow = NSBezierPath()
    bow.move(to: NSPoint(x: 723, y: 665))
    bow.curve(to: NSPoint(x: 620, y: 720),
              controlPoint1: NSPoint(x: 687, y: 708), controlPoint2: NSPoint(x: 627, y: 750))
    bow.curve(to: NSPoint(x: 622, y: 617),
              controlPoint1: NSPoint(x: 594, y: 695), controlPoint2: NSPoint(x: 592, y: 628))
    bow.curve(to: NSPoint(x: 723, y: 665),
              controlPoint1: NSPoint(x: 655, y: 609), controlPoint2: NSPoint(x: 697, y: 641))
    bow.curve(to: NSPoint(x: 825, y: 725),
              controlPoint1: NSPoint(x: 754, y: 710), controlPoint2: NSPoint(x: 813, y: 750))
    bow.curve(to: NSPoint(x: 829, y: 623),
              controlPoint1: NSPoint(x: 850, y: 700), controlPoint2: NSPoint(x: 859, y: 637))
    bow.curve(to: NSPoint(x: 723, y: 665),
              controlPoint1: NSPoint(x: 796, y: 609), controlPoint2: NSPoint(x: 752, y: 641))
    bow.close()
    pink.setFill()
    bow.fill()
    rounded(NSRect(x: 703, y: 644, width: 43, height: 44), radius: 17, color: darkPink)
    rounded(NSRect(x: 364, y: 454, width: 35, height: 62), radius: 18, color: navy)
    rounded(NSRect(x: 610, y: 454, width: 35, height: 62), radius: 18, color: navy)
    rounded(NSRect(x: 307, y: 420, width: 66, height: 27), radius: 14, color: peach)
    rounded(NSRect(x: 637, y: 420, width: 66, height: 27), radius: 14, color: peach)
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: 450, y: 443))
    smile.curve(to: NSPoint(x: 560, y: 443),
                controlPoint1: NSPoint(x: 470, y: 393), controlPoint2: NSPoint(x: 540, y: 393))
    smile.lineWidth = 17
    smile.lineCapStyle = .round
    navy.setStroke()
    smile.stroke()
    for row in 0..<2 {
        for col in 0..<6 {
            let color: NSColor = (row + col).isMultiple(of: 2) ? navy : .white
            rounded(NSRect(x: 402 + col * 34, y: 300 + row * 34, width: 34, height: 34),
                    radius: 0, color: color.withAlphaComponent(0.85))
        }
    }
    peach.setFill()
    let star = NSBezierPath()
    star.move(to: NSPoint(x: 802, y: 745))
    star.line(to: NSPoint(x: 818, y: 785))
    star.line(to: NSPoint(x: 858, y: 801))
    star.line(to: NSPoint(x: 818, y: 817))
    star.line(to: NSPoint(x: 802, y: 857))
    star.line(to: NSPoint(x: 786, y: 817))
    star.line(to: NSPoint(x: 746, y: 801))
    star.line(to: NSPoint(x: 786, y: 785))
    star.close()
    star.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    return png
}

for base in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        try drawIcon(size: base * multiplier)
            .write(to: directory.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
