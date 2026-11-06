// Renders Resources/AppIcon.icns: a dark tile with a glowing "{ Z }" glyph.
import AppKit
let out = CommandLine.arguments[1]
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1), NSColor(red: 0.16, green: 0.12, blue: 0.28, alpha: 1)])!.draw(in: tile, angle: -70)
    // accent ring
    NSGraphicsContext.current?.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [NSColor(red: 1, green: 0.35, blue: 0.55, alpha: 0.55), .clear])!.draw(in: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.6), angle: 90)
    NSGraphicsContext.current?.restoreGraphicsState()
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let font = NSFont.monospacedSystemFont(ofSize: s * 0.30, weight: .heavy)
    let grad = NSGradient(colors: [NSColor(red: 1, green: 0.55, blue: 0.3, alpha: 1), NSColor(red: 0.95, green: 0.3, blue: 0.7, alpha: 1), NSColor(red: 0.45, green: 0.45, blue: 1, alpha: 1)])!
    let text = NSAttributedString(string: "{Z}", attributes: [.font: font, .paragraphStyle: para, .foregroundColor: NSColor.white])
    let size = text.size()
    let tr = NSRect(x: r.minX, y: r.midY - size.height / 2, width: r.width, height: size.height)
    // gradient-filled text via mask
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus(); text.draw(in: tr); img.unlockFocus()
    NSGraphicsContext.current?.saveGraphicsState()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clip(to: CGRect(x: 0, y: 0, width: s, height: s), mask: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    grad.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -30)
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base)@2x.png"))
}
