// Draws the Glimpse app icon and writes a 1024 × 1024 PNG.
// Usage: swift scripts/generate-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
guard let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot create the drawing context")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linearGradient(_ colors: [CGColor], in path: CGPath, from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

// The macOS icon grid: an 824 pt rounded square inside a 1024 pt canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundedRect(body, 185)

// Drop shadow under the body.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
context.addPath(bodyPath)
context.setFillColor(color(0x1B1446))
context.fillPath()
context.restoreGState()

// Deep violet to blue background.
linearGradient([color(0x6A3DF0), color(0x2B1C8F), color(0x0F1240)], in: bodyPath,
               from: CGPoint(x: body.minX, y: body.maxY), to: CGPoint(x: body.maxX, y: body.minY))

// Soft glow in the upper left.
context.saveGState()
context.addPath(bodyPath)
context.clip()
let glow = CGGradient(colorsSpace: colorSpace, colors: [color(0xFF7AD9, 0.55), color(0xFF7AD9, 0)] as CFArray, locations: nil)!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 760), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 760), endRadius: 520, options: [])
context.restoreGState()

// The back photo card, turned to the left.
func card(center: CGPoint, angle: CGFloat, fill: [CGColor], alpha: CGFloat) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: angle)
    let rect = CGRect(x: -230, y: -175, width: 460, height: 350)
    let path = roundedRect(rect, 52)
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.35))
    context.setAlpha(alpha)
    context.addPath(path)
    context.setFillColor(fill[0])
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    linearGradient(fill, in: path, from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY))
    context.restoreGState()
}

card(center: CGPoint(x: 470, y: 560), angle: 0.16, fill: [color(0xFFFFFF, 0.55), color(0xC9C2FF, 0.45)], alpha: 0.75)

// The front photo card with a landscape.
let frontCenter = CGPoint(x: 545, y: 470)
context.saveGState()
context.translateBy(x: frontCenter.x, y: frontCenter.y)
context.rotate(by: -0.08)
let frontRect = CGRect(x: -245, y: -185, width: 490, height: 370)
let frontPath = roundedRect(frontRect, 56)
context.setShadow(offset: CGSize(width: 0, height: -22), blur: 50, color: color(0x000000, 0.45))
context.addPath(frontPath)
context.setFillColor(color(0xFFFFFF))
context.fillPath()
context.setShadow(offset: .zero, blur: 0, color: nil)

// Sky.
let inner = frontRect.insetBy(dx: 26, dy: 26)
let innerPath = roundedRect(inner, 34)
linearGradient([color(0xFFB36B), color(0xFF5E9C), color(0x7B5CFF)], in: innerPath,
               from: CGPoint(x: 0, y: inner.maxY), to: CGPoint(x: 0, y: inner.minY))

context.saveGState()
context.addPath(innerPath)
context.clip()
// Sun.
context.setFillColor(color(0xFFF4D6, 0.95))
context.fillEllipse(in: CGRect(x: 70, y: 40, width: 96, height: 96))
// Mountains.
let far = CGMutablePath()
far.move(to: CGPoint(x: inner.minX, y: inner.minY))
far.addLine(to: CGPoint(x: inner.minX, y: -40))
far.addLine(to: CGPoint(x: -90, y: 60))
far.addLine(to: CGPoint(x: 10, y: -10))
far.addLine(to: CGPoint(x: 120, y: 70))
far.addLine(to: CGPoint(x: inner.maxX, y: -30))
far.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
far.closeSubpath()
linearGradient([color(0x5B3FD9), color(0x2A1E7A)], in: far, from: CGPoint(x: 0, y: 70), to: CGPoint(x: 0, y: inner.minY))
let near = CGMutablePath()
near.move(to: CGPoint(x: inner.minX, y: inner.minY))
near.addLine(to: CGPoint(x: inner.minX, y: -90))
near.addLine(to: CGPoint(x: -40, y: -20))
near.addLine(to: CGPoint(x: 60, y: -100))
near.addLine(to: CGPoint(x: 150, y: -50))
near.addLine(to: CGPoint(x: inner.maxX, y: -110))
near.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
near.closeSubpath()
linearGradient([color(0x24186A), color(0x120C3A)], in: near, from: CGPoint(x: 0, y: -20), to: CGPoint(x: 0, y: inner.minY))
context.restoreGState()
context.restoreGState()

// A thin highlight along the top edge of the body.
context.saveGState()
context.addPath(bodyPath)
context.setStrokeColor(color(0xFFFFFF, 0.18))
context.setLineWidth(3)
context.strokePath()
context.restoreGState()

guard let image = context.makeImage() else { fatalError("Cannot render the icon") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
try data.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
