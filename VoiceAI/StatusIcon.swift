import AppKit

/// The menu bar icon: a wave in the level bar's colours inside a circle or a pill, picked in
/// Settings. Drawn in code rather than from assets, because the wave moves — it follows the
/// voice while recording and ripples while Whisper works. The outline lights up in colour only
/// while recording — the fully coloured styles went in 0.1.32 ([U]: colour shows when you speak).
enum IconStyle: String, CaseIterable {
    case circle = "circleBars", pill = "pillBars"

    static let fallback = IconStyle.circle

    /// The saved choice; the old fully coloured styles keep their shape.
    static func stored(_ raw: String?) -> IconStyle {
        raw == "pillBars" || raw == "pillColor" ? .pill : .circle
    }

    var title: String {
        switch self {
        case .circle: String(localized: "Mała — kółko")
        case .pill: String(localized: "Szeroka — pastylka")
        }
    }

    var isPill: Bool { self == .pill }
    var crestCount: Int { isPill ? 6 : 5 }

    /// Wave crests at rest (0…1) — the shape from the chosen sketch.
    var restingLevels: [CGFloat] {
        isPill ? [0.3, 0.6, 0.84, 0.5, 0.8, 0.4] : [0.27, 0.64, 1, 0.64, 0.27]
    }
}

enum StatusIcon {
    enum Mode { case idle, loading, active, working, failed, noMicrophone }

    static func image(style: IconStyle, mode: Mode, levels: [CGFloat], whisper: Bool) -> NSImage {
        let size = style.isPill ? NSSize(width: 34, height: 18) : NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(style: style, mode: mode, levels: levels, whisper: whisper, size: size, in: context)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "VoiceAI"
        return image
    }

    // MARK: - Drawing

    private static func draw(style: IconStyle, mode: Mode, levels: [CGFloat], whisper: Bool,
                             size: NSSize, in context: CGContext) {
        let outline = style.isPill
            ? CGPath(roundedRect: CGRect(x: 1, y: 1.5, width: 32, height: 15), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
            : CGPath(ellipseIn: CGRect(x: 1.65, y: 1.65, width: 14.7, height: 14.7), transform: nil)
        let lineWidth: CGFloat = style.isPill ? 1.6 : 1.3
        let neutral = mode == .failed ? NSColor.secondaryLabelColor : NSColor.labelColor
        // Whisper mode at rest: the shape filled night blue with a pale wave — the small moon
        // this replaced was nearly invisible at menu bar size. Recording still lights up.
        let night = whisper && mode != .active

        // Recording lights the shape up: a faint colour wash inside and a colour outline.
        if mode == .active {
            context.saveGState()
            context.addPath(outline)
            context.clip()
            fillGradient(in: context, width: size.width, alpha: 0.28)
            context.restoreGState()
        }
        if night {
            let filled = style.isPill
                ? CGPath(roundedRect: CGRect(x: 0.5, y: 1, width: 33, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil)
                : CGPath(ellipseIn: CGRect(x: 1, y: 1, width: 16, height: 16), transform: nil)
            context.addPath(filled)
            context.setFillColor(Self.nightFill.withAlphaComponent(mode == .loading ? 0.5 : 1).cgColor)
            context.fillPath()
        } else if mode == .active {
            context.saveGState()
            context.addPath(outline.copy(strokingWithWidth: lineWidth + (mode == .active ? 0.3 : 0),
                                         lineCap: .round, lineJoin: .round, miterLimit: 10))
            context.clip()
            fillGradient(in: context, width: size.width, alpha: 1)
            context.restoreGState()
        } else {
            context.addPath(outline)
            context.setStrokeColor(neutral.cgColor)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }

        // One wave through the old bar positions: each level is a crest, alternately up and
        // down, so the resting shape swells in the middle and the voice makes it ripple.
        let xs: [CGFloat] = style.isPill ? [8, 11.5, 15, 18.5, 22, 25.5] : [4.9, 6.9, 9, 11.1, 13.1]
        let ends: (CGFloat, CGFloat) = style.isPill ? (4, 30) : (3.2, 14.8)
        let amplitude: CGFloat = style.isPill ? 5.25 : 4.5
        let mid = size.height / 2
        var points = [CGPoint(x: ends.0, y: mid)]
        for (index, x) in xs.enumerated() {
            let level = mode == .failed ? 0 : (index < levels.count ? levels[index] : 0)
            points.append(CGPoint(x: x, y: mid + (index.isMultiple(of: 2) ? 1 : -1) * amplitude * level))
        }
        points.append(CGPoint(x: ends.1, y: mid))
        let wave = smoothPath(through: points)
            .copy(strokingWithWidth: style.isPill ? 1.6 : 1.35, lineCap: .round, lineJoin: .round, miterLimit: 10)
        // Loading and no microphone: the usual wave, dimmed.
        let alpha: CGFloat = mode == .loading || mode == .noMicrophone ? 0.35 : 1
        context.saveGState()
        context.addPath(wave)
        if mode == .failed || night {
            context.setFillColor((mode == .failed ? neutral : Self.nightBars).withAlphaComponent(alpha).cgColor)
            context.fillPath()
        } else {
            context.clip()
            fillGradient(in: context, from: xs.first!, to: xs.last!, alpha: alpha)
        }
        context.restoreGState()
    }

    /// A Catmull-Rom curve through the points, so the wave has no corners at the crests.
    private static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 0..<points.count - 1 {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    private static let nightFill = NSColor(srgbRed: 0x3D / 255, green: 0x3A / 255, blue: 0x9E / 255, alpha: 1)
    private static let nightBars = NSColor(srgbRed: 0xE6 / 255, green: 0xE4 / 255, blue: 0xFF / 255, alpha: 1)

    private static func fillGradient(in context: CGContext, width: CGFloat, alpha: CGFloat) {
        fillGradient(in: context, from: 0, to: width, alpha: alpha)
    }

    private static func fillGradient(in context: CGContext, from start: CGFloat, to end: CGFloat, alpha: CGFloat) {
        let colors = [0, 0.5, 1].map { Voice.color(at: $0).withAlphaComponent(alpha).cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.5, 1]) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: start, y: 0), end: CGPoint(x: end, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
