// Draws the app icon (1024x1024 PNG). Usage: swift tools/make-icon.swift out.png
import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 100, r: CGFloat = 185
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(path); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(hue: 0.62, saturation: 0.55, brightness: 0.22, alpha: 1).cgColor,
                               NSColor(hue: 0.80, saturation: 0.55, brightness: 0.30, alpha: 1).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// "mini window" card
let card = CGRect(x: 200, y: 330, width: 624, height: 300)
ctx.addPath(CGPath(roundedRect: card, cornerWidth: 60, cornerHeight: 60, transform: nil))
ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor); ctx.fillPath()
// play button
let accent = NSColor(hue: 0.47, saturation: 0.62, brightness: 1.0, alpha: 1).cgColor
ctx.setFillColor(accent)
ctx.fillEllipse(in: CGRect(x: 250, y: 380, width: 200, height: 200))
ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
ctx.move(to: CGPoint(x: 325, y: 430)); ctx.addLine(to: CGPoint(x: 325, y: 530)); ctx.addLine(to: CGPoint(x: 410, y: 480)); ctx.closePath(); ctx.fillPath()
// music bars
let heights: [CGFloat] = [120, 200, 150, 230, 100]
for (i, h) in heights.enumerated() {
  let x = 500 + CGFloat(i) * 62
  ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 480 - h / 2, width: 38, height: h), cornerWidth: 19, cornerHeight: 19, transform: nil))
  ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor); ctx.fillPath()
}
// pin
ctx.setFillColor(accent)
ctx.fillEllipse(in: CGRect(x: 680, y: 690, width: 90, height: 90))
ctx.fill(CGRect(x: 717, y: 640, width: 16, height: 60))
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
