// Renders VoiceAI's app icon into VoiceAI/Assets.xcassets/AppIcon.appiconset: the menu bar
// icon (a ring with a wave in the level bar's blue → purple → pink) on a dark squircle.
// The body sits on Apple's macOS grid — 824 of 1024 px, 100 px margin — so the system shows it
// as a full icon. By hand: swift Tools/make-icon.swift (output is committed, not built).
import AppKit

let output = URL(fileURLWithPath: "VoiceAI/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

// The system colours the level bar uses (dark appearance), sampled at the five crest positions.
let waveColors = [0x0A84FF, 0x656FF9, 0xBF5AF2, 0xDF49A9, 0xFF375F].map(color)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: px * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let k = CGFloat(px) / 1024
    c.scaleBy(x: k, y: k)

    // Dark squircle body with a gentle top-to-bottom shade.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.addPath(body)
    c.clip()
    let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [color(0x2C2B36), color(0x121217)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(shade, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()

    // Ring and wave, the menu bar icon's proportions (24-unit grid, ring radius 9.8).
    let unit: CGFloat = 29
    c.setStrokeColor(color(0xF2F2F7))
    c.setLineWidth(1.6 * unit)
    c.strokeEllipse(in: CGRect(x: 512 - 9.8 * unit, y: 512 - 9.8 * unit, width: 19.6 * unit, height: 19.6 * unit))
    // One wave through five crests, alternately up and down, like the menu bar icon.
    let offsets: [CGFloat] = [-5.5, -2.8, 0, 2.8, 5.5]
    // Uneven, like a voice caught mid-word — not the calm symmetric shape of the menu bar icon.
    let crests: [CGFloat] = [2.3, 4.8, 3, 5.6, 2.5]
    var points = [CGPoint(x: 512 - 7.6 * unit, y: 512)]
    for i in 0..<5 {
        points.append(CGPoint(x: 512 + offsets[i] * unit, y: 512 + (i.isMultiple(of: 2) ? -1 : 1) * crests[i] * unit))
    }
    points.append(CGPoint(x: 512 + 7.6 * unit, y: 512))
    let wave = CGMutablePath()
    wave.move(to: points[0])
    // Catmull-Rom, so the crests are round.
    for i in 0..<points.count - 1 {
        let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
        wave.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    c.saveGState()
    c.addPath(wave.copy(strokingWithWidth: 1.7 * unit, lineCap: .round, lineJoin: .round, miterLimit: 10))
    c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: waveColors as CFArray,
                              locations: [0, 0.25, 0.5, 0.75, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512 + offsets[0] * unit, y: 0),
                         end: CGPoint(x: 512 + offsets[4] * unit, y: 0),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (point, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = point * scale
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: output.appending(path: name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(point)x\(point)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appending(path: "Contents.json"))
print("Icon written: \(images.count) sizes")
