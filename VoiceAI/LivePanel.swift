import AppKit

/// A small floating pill at the bottom of the screen, the way Wispr Flow does it: a level
/// wave while the key is held, then "Rozpoznaję…" until the text lands. No live text — Whisper
/// only reads whole chunks of audio, so any live text was either late or wrong (0.1.2–0.1.4).
/// The pill never takes focus: the text must still land in the app you speak into.
/// On the left it shows where the text is going — the app and its window, or the journal —
/// so a stray focus in another window is caught before the text lands there.
final class LivePanel {
    private static let height: CGFloat = 40
    private static let waveWidth: CGFloat = 150
    /// The app name and window title are cut beyond this.
    private static let maxTargetWidth: CGFloat = 180

    private let panel: NSPanel
    private let wave = LevelWave()
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let appName = NSTextField(labelWithString: "")
    private let windowTitle = NSTextField(labelWithString: "")
    private let targetView = NSStackView()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.height / 2

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        wave.heightAnchor.constraint(equalToConstant: 20).isActive = true

        appName.font = .systemFont(ofSize: 12, weight: .semibold)
        windowTitle.font = .systemFont(ofSize: 11)
        windowTitle.textColor = .secondaryLabelColor
        for field in [appName, windowTitle] {
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
        }
        let names = NSStackView(views: [appName, windowTitle])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 0
        targetView.setViews([icon, names], in: .leading)
        targetView.spacing = 7
        targetView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(targetView)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            targetView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            targetView.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            targetView.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxTargetWidth),
        ])
        // The wave sits right after the name — the pill is as wide as its content.
        for view in [wave, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: targetView.trailingAnchor, constant: 14),
                view.widthAnchor.constraint(equalToConstant: Self.waveWidth),
                view.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            ])
        }
        panel.contentView = background
    }

    /// Where the text will land: shown next to the wave and updated while you speak.
    func target(_ destination: Paster.Destination) {
        icon.image = destination.icon
        appName.stringValue = destination.name
        windowTitle.stringValue = destination.title ?? ""
        windowTitle.isHidden = destination.title?.isEmpty ?? true
        fitWidth()
    }

    private var width: CGFloat {
        let target = min(targetView.fittingSize.width, Self.maxTargetWidth)
        return 12 + target + 14 + Self.waveWidth + 16
    }

    /// Resizes around the same centre when the name changes while the pill is on screen.
    private func fitWidth() {
        let frame = panel.frame
        guard abs(frame.width - width) > 0.5 else { return }
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: Self.height), display: true)
    }

    func listening() {
        wave.reset()
        wave.isHidden = false
        label.isHidden = true
        show()
    }

    /// Loudness (RMS) from the microphone, pushed a few dozen times a second.
    func level(_ rms: Float) {
        wave.push(rms)
    }

    func working(_ text: String = String(localized: "Rozpoznaję…")) {
        label.textColor = .secondaryLabelColor
        label.stringValue = text
        wave.isHidden = true
        label.isHidden = false
        show()
    }

    /// A warning in the wave's place: a red symbol and red text — no microphone (0.1.66).
    func alert(_ text: String, symbol: String) {
        let line = NSMutableAttributedString()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(.init(paletteColors: [.systemRed]))
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let attachment = NSTextAttachment()
            attachment.image = image
            line.append(NSAttributedString(attachment: attachment))
            line.append(NSAttributedString(string: " "))
        }
        line.append(NSAttributedString(string: text))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        line.addAttributes([.foregroundColor: NSColor.systemRed, .font: label.font as Any,
                            .paragraphStyle: centered], range: NSRange(location: 0, length: line.length))
        label.attributedStringValue = line
        wave.isHidden = true
        label.isHidden = false
        show()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show() {
        guard !panel.isVisible else { return }
        // The screen with the mouse — that is where the user is looking.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 80, width: width, height: Self.height), display: true)
        panel.orderFrontRegardless()
    }
}

/// A wave through the latest levels, newest on the right, flowing left as they come: its
/// height at each point is the voice level of that moment, like the menu bar icon.
private final class LevelWave: NSView {
    private static let count = 22
    /// One ripple of the wave, in points.
    private static let wavelength: CGFloat = 18
    private var levels = [CGFloat](repeating: 0, count: count)
    /// How far the wave has flowed — it moves one level step per push, so the ripples and the
    /// loudness travel together.
    private var offset: CGFloat = 0

    func reset() {
        levels = [CGFloat](repeating: 0, count: Self.count)
        offset = 0
        needsDisplay = true
    }

    func push(_ rms: Float) {
        levels.removeFirst()
        levels.append(Voice.level(rms))
        offset += bounds.width / CGFloat(Self.count - 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let lineWidth: CGFloat = 2
        let mid = bounds.midY
        let room = bounds.height / 2 - lineWidth
        let step = bounds.width / CGFloat(Self.count - 1)
        let path = CGMutablePath()
        var x: CGFloat = lineWidth / 2
        while x <= bounds.width - lineWidth / 2 {
            // Loudness between the two nearest samples, eased so the envelope has no kinks.
            let position = x / step
            let index = min(Int(position), Self.count - 2)
            let t = position - CGFloat(index)
            let eased = t * t * (3 - 2 * t)
            let level = levels[index] + (levels[index + 1] - levels[index]) * eased
            let y = mid + room * max(level, 0.06) * sin(2 * .pi * (x + offset) / Self.wavelength)
            if x == lineWidth / 2 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            x += 0.5
        }
        context.addPath(path.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10))
        context.clip()
        let colors = [0, 0.5, 1].map { Voice.color(at: $0).cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.5, 1]) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: bounds.width, y: 0), options: [])
    }
}

/// Shared by the level bar and the menu bar icon, so both look like one thing.
enum Voice {
    /// Blue → purple → pink from left to right.
    private static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemPink]

    static func color(at position: CGFloat) -> NSColor {
        let scaled = min(max(position, 0), 1) * CGFloat(palette.count - 1)
        let index = min(Int(scaled), palette.count - 2)
        return palette[index].blended(withFraction: scaled - CGFloat(index), of: palette[index + 1]) ?? palette[index]
    }

    /// Microphone RMS as 0…1 — speech sits roughly between -50 dB (quiet) and -10 dB (loud).
    static func level(_ rms: Float) -> CGFloat {
        let db = 20 * log10(max(rms, 1e-6))
        return CGFloat(min(max((db + 50) / 40, 0), 1))
    }
}
