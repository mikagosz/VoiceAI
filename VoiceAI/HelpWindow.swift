import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Help window: a big title, then sections with a picture of the app on one side and the steps on the
// other, sides taking turns. Numbered points on a picture match the numbered steps.
//
// The pictures are drawn by VoiceAI itself, on sample data. The Settings and Journal windows are rendered off
// screen from the very same SwiftUI views, fed with a sample word list, journal and models folder in a temporary
// folder and a separate settings store (`.defaultAppStorage`), so nothing of the user's settings, microphone,
// journal or dictations gets in and nothing real is written. The menu bar icon comes from StatusIcon itself;
// the level bar, the menu and the other windows around it are drawn here with the app's own texts.

@MainActor
final class HelpWindow {
    static let shared = HelpWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = L("VoiceAI — Pomoc")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HelpPage(pictures: HelpPictures.make()))
            // A fixed height: an `idealHeight` alone gave the window 432 pt (measured in DeskMount 0.1.50).
            w.setContentSize(NSSize(width: HelpPage.width, height: HelpPage.height))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A text of the Help window in the app's language (Localizable.xcstrings; the key is the Polish text).
func L(_ polish: String) -> String { Bundle.main.localizedString(forKey: polish, value: polish, table: nil) }

// MARK: - Sample data

/// A sample world for the pictures: its own settings store and a temporary data folder, both removed
/// once the pictures are made.
@MainActor
enum HelpSample {
    static let suite = "com.mikagosz.VoiceAI.help-sample"

    /// The speech language of the pictures: the language Help is shown in.
    static var language: String { Language.interfaceIsPolish ? "pl" : "en" }

    static func vocabulary() -> Vocabulary {
        Vocabulary(jezyk: language, slowa: HelpContent.sampleWords, zamiany: HelpContent.sampleSwaps,
                   aplikacje: ["com.apple.Terminal": AppRule(nazwa: "Terminal", kropka: false),
                               "com.apple.mail": AppRule(nazwa: "Mail", wielkaLitera: true)])
    }

    static func day(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: day, hour: hour, minute: minute)) ?? Date()
    }

    /// Runs `make` with the sample settings store and data folder, then removes both.
    static func with<T>(_ make: (UserDefaults, URL) -> T) -> T {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let folder = FileManager.default.temporaryDirectory.appending(path: "VoiceAI-help-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        return make(defaults, folder)
    }
}

/// Bitmaps of the app's own windows on sample data, made when the Help window opens.
@MainActor
struct HelpPictures {
    let settings: NSImage
    let journal: NSImage

    static let settingsSize = NSSize(width: 620, height: 2400)
    static let journalSize = NSSize(width: 520, height: 360)

    static func make() -> HelpPictures {
        HelpSample.with { defaults, folder in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try? encoder.encode(HelpSample.vocabulary()).write(to: folder.appending(path: "slownik.json"))
            let vocabulary = VocabularyStore(directory: folder)
            vocabulary.reload()
            let options = OptionsView(vocabulary: vocabulary, textModel: TextModel(directory: folder),
                                      speaker: Speaker(defaults: defaults), sample: true)
                .defaultAppStorage(defaults)
            let journal = Journal(directory: folder)
            let times = [(12, 8, 5), (12, 17, 40), (13, 9, 12), (13, 11, 30)]
            for (text, t) in zip(HelpContent.sampleJournal, times) {
                try? journal.add(L(text), at: HelpSample.day(t.0, t.1, t.2))
            }
            return HelpPictures(settings: Render.window(options, size: settingsSize),
                                journal: Render.window(JournalView(journal: journal), size: journalSize))
        }
    }
}

@MainActor
enum Render {
    /// A view drawn into a bitmap at twice its size, so it stays sharp on a Retina screen.
    static func bitmap(_ v: NSView) -> NSImage {
        let b = v.bounds
        guard b.width >= 1, b.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = b.size
        v.cacheDisplay(in: b, to: rep)
        let image = NSImage(size: b.size)
        image.addRepresentation(rep)
        return image
    }

    /// A window's content rendered off screen: the same controls and texts the user sees.
    /// NSHostingView, not ImageRenderer — ImageRenderer draws forms empty and segmented pickers as a "no" sign.
    static func window<V: View>(_ view: V, size: NSSize) -> NSImage {
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSApp.effectiveAppearance
        // In a plain view with the window's own background, so no strip of the form is left transparent.
        let back = NSView(frame: NSRect(origin: .zero, size: size))
        back.wantsLayer = true
        host.frame = back.bounds
        back.addSubview(host)
        w.contentView = back
        back.layoutSubtreeIfNeeded()
        // Lists and forms load their rows only when drawn — one turn of the run loop after a first display,
        // so the bitmap has them (Change-Boot 0.2.29: empty pictures in the app).
        back.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        back.layoutSubtreeIfNeeded()
        var image = NSImage()
        w.effectiveAppearance.performAsCurrentDrawingAppearance {
            back.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            image = bitmap(back)
        }
        w.contentView = nil
        return image
    }

    /// The menu bar icon at `scale`, drawn under a dark menu bar's appearance — StatusIcon picks its
    /// neutral colour at draw time.
    static func icon(_ image: NSImage, scale: CGFloat) -> NSImage {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        var out = NSImage()
        (NSAppearance(named: .darkAqua) ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            out = NSImage(size: size)
            out.addRepresentation(rep)
        }
        return out
    }
}

extension NSImage {
    /// A piece of the picture, in points from its top-left corner — like a cut-out screenshot.
    func cutOut(_ r: CGRect) -> NSImage {
        if r == CGRect(origin: .zero, size: size) { return self }
        return NSImage(size: r.size, flipped: false) { _ in
            self.draw(in: NSRect(x: -r.minX, y: r.maxY - self.size.height, width: self.size.width, height: self.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

// MARK: - The page

struct HelpPage: View {
    static let width: CGFloat = 960
    static var height: CGFloat { min(900, (NSScreen.main?.visibleFrame.height ?? 900) - 80) }

    let pictures: HelpPictures
    /// For the bitmap of the whole page (`--export-help`): no scrolling, every section unfolded.
    var wholePage = false

    var body: some View {
        if wholePage {
            content.frame(width: Self.width).background(Color(nsColor: .windowBackgroundColor))
        } else {
            // Opens at the title: without the anchor the window came up scrolled a little way down.
            ScrollView { content }
                .defaultScrollAnchor(.top)
                .frame(width: Self.width, height: Self.height)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(HelpContent.sections.enumerated()), id: \.offset) { i, s in
                Divider().padding(.horizontal, 60)
                HelpSection(section: s, pictureLeft: i % 2 == 0, pictures: pictures, expanded: wholePage)
            }
            Divider().padding(.horizontal, 60)
            goodToKnow
            FractalSignature()
        }
        .padding(.bottom, 40)
    }

    private var header: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 96, height: 96)
            Text(verbatim: L(HelpContent.title)).font(.system(size: 40, weight: .semibold))
            Text(verbatim: L(HelpContent.intro))
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 640)
                .fixedSize(horizontal: false, vertical: true)
            HeaderPicture().padding(.top, 8)
        }
        .padding(.top, 44).padding(.bottom, 48).padding(.horizontal, 60)
    }

    private var goodToKnow: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: L(HelpContent.goodToKnow)).font(.system(size: 30, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20, alignment: .top), GridItem(.flexible(), spacing: 20, alignment: .top)],
                      spacing: 20) {
                ForEach(HelpContent.cards, id: \.title) { c in
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: c.symbol).font(.system(size: 22)).foregroundStyle(Color.accentColor)
                        Text(verbatim: L(c.title)).font(.headline)
                        Text(verbatim: L(c.text)).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
                }
            }
        }
        .padding(.top, 40).padding(.horizontal, 60)
    }
}

private struct HelpSection: View {
    let section: HelpContent.Section
    let pictureLeft: Bool
    let pictures: HelpPictures
    @State var expanded: Bool

    /// The Settings window is wide: its pictures stand under the text at 1:1, not squeezed beside it.
    private var wide: Bool { [.settings, .replies, .model].contains(section.picture) }

    var body: some View {
        Group {
            if wide {
                VStack(alignment: .leading, spacing: 28) {
                    text
                    picture.frame(maxWidth: .infinity)
                }
            } else {
                HStack(alignment: .center, spacing: 44) {
                    if pictureLeft { picture }
                    text
                    if !pictureLeft { picture }
                }
            }
        }
        .padding(.vertical, 44).padding(.horizontal, 60)
    }

    private var picture: some View {
        Group {
            switch section.picture {
            case .dictate: DictatePicture()
            case .icon: IconPicture()
            case .menu: MenuPicture()
            case .settings: WindowPicture(image: pictures.settings, crop: HelpCrops.settings, maxWidth: 840)
            case .vocabulary: VocabularyPicture()
            case .journal: WindowPicture(image: pictures.journal, crop: HelpCrops.journal)
            case .files: FilesPicture()
            case .replies: WindowPicture(image: pictures.settings, crop: HelpCrops.replies, maxWidth: 840)
            case .model: WindowPicture(image: pictures.settings, crop: HelpCrops.model, maxWidth: 840)
            }
        }
        .frame(width: wide ? nil : 440)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L(section.title)).font(.system(size: 30, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: L(section.lead)).font(.system(size: 15)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(section.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Marker(number: i + 1, small: true)
                        Text(verbatim: L(step)).font(.system(size: 14)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let more = section.more {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Label(L(expanded ? HelpContent.less : HelpContent.more), systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.link)
                if expanded {
                    Text(verbatim: L(more)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Cut-outs and points

/// Where to cut a window and where its numbered points stand, in points of the window.
/// x < 0: the point stands in the margin on the left, level with the row — it covers no text.
struct Crop {
    let rect: CGRect
    let points: [CGPoint?]

    static func m(_ y: CGFloat) -> CGPoint { CGPoint(x: -1, y: y) }
}

/// Measured on `--export-help`.
enum HelpCrops {
    private static func m(_ y: CGFloat) -> CGPoint { Crop.m(y) }
    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static let settings = Crop(rect: CGRect(x: 0, y: 118, width: 620, height: 285), points: [m(54), m(95), m(134), m(209)])
    static let replies = Crop(rect: CGRect(x: 0, y: 628, width: 620, height: 277), points: [m(53), m(90), m(129)])
    static let model = Crop(rect: CGRect(x: 0, y: 1120, width: 620, height: 310), points: [m(60), m(254), m(291)])
    static let journal = Crop(rect: CGRect(origin: .zero, size: HelpPictures.journalSize), points: [m(111), m(45), p(255, 337)])
}

/// A window picture in a section: the cut-out, its frame and the numbered points.
/// Never enlarged beyond 1:1 — bigger than the window it would look like a screenshot under a magnifier.
struct WindowPicture: View {
    let image: NSImage
    let crop: Crop
    var maxWidth: CGFloat = 440
    private let margin: CGFloat = 36

    var body: some View {
        let r = crop.rect
        let left: CGFloat = crop.points.contains { ($0?.x ?? 0) < 0 } ? margin : 0
        let w = min(maxWidth - left, r.width)
        let scale = w / r.width
        let h = r.height * scale
        Frame {
            HStack(spacing: 0) {
                Color.clear.frame(width: left, height: h)
                Image(nsImage: image.cutOut(r)).resizable().interpolation(.high).frame(width: w, height: h)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(crop.points.enumerated()), id: \.offset) { i, p in
                        if let p {
                            Marker(number: i + 1).position(x: p.x < 0 ? margin / 2 + 2 : left + p.x * scale, y: p.y * scale)
                        }
                    }
                }
                .frame(width: left + w, height: h, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Pictures drawn for Help

/// A calm desktop background.
private struct Desktop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.42, green: 0.30, blue: 0.52),
                                Color(red: 0.78, green: 0.52, blue: 0.48)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Sample loudness for a wave in mid-sentence, 0…1 per point of the level bar.
private enum SampleLevels {
    static let speech: [CGFloat] = [0.05, 0.1, 0.3, 0.55, 0.8, 0.65, 0.4, 0.6, 0.9, 1, 0.75, 0.5, 0.35, 0.55, 0.7, 0.85,
                                    0.6, 0.4, 0.25, 0.45, 0.3, 0.15]
    static let icon: [CGFloat] = [0.45, 0.9, 0.6, 1, 0.5]
}

/// The level bar's wave as LevelWave draws it (LivePanel.swift): a ripple whose height follows the voice,
/// in the blue → purple → pink of the menu bar icon.
private struct WaveShape: View {
    let levels: [CGFloat]

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            let lineWidth: CGFloat = 2
            let mid = size.height / 2
            let room = size.height / 2 - lineWidth
            let step = size.width / CGFloat(count - 1)
            var path = Path()
            var x: CGFloat = lineWidth / 2
            while x <= size.width - lineWidth / 2 {
                let position = x / step
                let index = min(Int(position), count - 2)
                let t = position - CGFloat(index)
                let eased = t * t * (3 - 2 * t)
                let level = levels[index] + (levels[index + 1] - levels[index]) * eased
                let y = mid + room * max(level, 0.06) * sin(2 * .pi * x / 18)
                if x == lineWidth / 2 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 0.5
            }
            let gradient = Gradient(colors: [0, 0.5, 1].map { Color(nsColor: Voice.color(at: $0)) })
            context.stroke(path, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The level bar at the bottom of the screen (LivePanel): where the text goes, then the wave.
private struct LevelPill: View {
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app"))
                    .resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: L(HelpContent.sampleApp)).font(.system(size: 12, weight: .semibold))
                    Text(verbatim: L(HelpContent.sampleWindow)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .lineLimit(1).fixedSize()
            }
            WaveShape(levels: SampleLevels.speech).frame(width: 150, height: 20)
        }
        .padding(.leading, 12).padding(.trailing, 16)
        .frame(height: 40)
        .background(Capsule().fill(Color(white: 0.16).opacity(0.94)))
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }
}

/// A strip of menu bar with the VoiceAI icon in the given state.
private struct MenuBarStrip: View {
    var mode: StatusIcon.Mode = .active

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(nsImage: Render.icon(StatusIcon.image(style: .circle, mode: mode,
                                                        levels: mode == .active ? SampleLevels.icon : IconStyle.circle.restingLevels,
                                                        whisper: false), scale: 1))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.22)))
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Image(systemName: "battery.75percent").font(.system(size: 15))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Color.black.opacity(0.28))
    }
}

/// The title picture: the menu bar with the icon lit up, and the level bar while you speak.
private struct HeaderPicture: View {
    var body: some View {
        Frame {
            ZStack(alignment: .top) {
                Desktop()
                MenuBarStrip()
                LevelPill().scaleEffect(1.5).frame(maxHeight: .infinity, alignment: .center).padding(.top, 26)
            }
            .frame(width: 660, height: 200)
        }
    }
}

/// A note being dictated into, and the level bar under it.
private struct DictatePicture: View {
    var body: some View {
        Frame {
            ZStack(alignment: .top) {
                Desktop()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 11, height: 11) }
                        Spacer()
                        Text(verbatim: L(HelpContent.sampleWindow)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Color.clear.frame(width: 47, height: 1)
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                    Divider()
                    (Text(verbatim: L(HelpContent.sampleNote)).foregroundStyle(.primary)
                        + Text(verbatim: "|").foregroundStyle(Color.accentColor).bold())
                        .font(.system(size: 14)).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                    Spacer(minLength: 0)
                }
                .frame(width: 330, height: 150)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .padding(.top, 26)
                LevelPill().padding(.top, 220)
            }
            .frame(width: 440, height: 290)
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Marker(number: 1).position(x: 36, y: 76)
                Marker(number: 2).position(x: 104, y: 218)
                Marker(number: 3).position(x: 330, y: 218)
            }
        }
    }
}

/// The menu bar icon in its states, from StatusIcon itself.
private struct IconPicture: View {
    private let states: [(StatusIcon.Mode, [CGFloat], Bool)] = [
        (.idle, IconStyle.circle.restingLevels, false), (.active, SampleLevels.icon, false),
        (.idle, IconStyle.circle.restingLevels, true), (.noMicrophone, IconStyle.circle.restingLevels, false),
    ]

    var body: some View {
        Frame {
            ZStack {
                Desktop()
                HStack(spacing: 22) {
                    ForEach(Array(states.enumerated()), id: \.offset) { i, s in
                        VStack(spacing: 14) {
                            Marker(number: i + 1)
                            Image(nsImage: Render.icon(StatusIcon.image(style: .circle, mode: s.0, levels: s.1, whisper: s.2), scale: 3.5))
                                .frame(width: 63, height: 63)
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.3)))
                        }
                    }
                }
            }
            .frame(width: 440, height: 220)
        }
    }
}

/// VoiceAI's menu, drawn with the texts of AppDelegate.menuNeedsUpdate and sample dictations.
private struct MenuPicture: View {
    var body: some View {
        Frame {
            ZStack(alignment: .topTrailing) {
                Desktop()
                VStack(alignment: .trailing, spacing: 0) {
                    MenuBarStrip(mode: .idle)
                    menu.padding(.trailing, 14).padding(.top, 4)
                }
            }
            .frame(width: 440, height: 500)
        }
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Marker(number: 1).position(x: 50, y: 42)
                Marker(number: 2).position(x: 50, y: 152)
                Marker(number: 3).position(x: 50, y: 218)
                Marker(number: 4).position(x: 50, y: 327)
            }
        }
    }

    private var menu: some View {
        let key = DictationKey.fallback.name
        let today = Stats.summary(Stats.Day(words: 412, seconds: 190))
        let week = Stats.summary(Stats.Day(words: 2_310, seconds: 1_080))
        return VStack(alignment: .leading, spacing: 0) {
            item(String(localized: "Gotowy — trzymaj \(key) i mów"), dim: true)
            item(String(localized: "Dziś: \(today)"), symbol: "chart.bar", dim: true)
            item(String(localized: "Ten tydzień: \(week)"), dim: true)
            divider
            item(String(localized: "Ostatnie — kliknij, by skopiować"), dim: true)
            ForEach(HelpContent.sampleHistory, id: \.self) { item(L($0)) }
            divider
            item(String(localized: "Przepisz plik audio lub wideo…"), symbol: "doc.text")
            item(String(localized: "Edytuj słownik…"))
            item(String(localized: "Tryb szeptu"), symbol: "mouth")
            item(String(localized: "Czytaj odpowiedzi Claude'a"), symbol: "asterisk", checked: true, orange: true)
            item(String(localized: "Głos"), symbol: "waveform", chevron: true)
            item(String(localized: "Dziennik…"), symbol: "book.closed")
            item(String(localized: "Ustawienia…"), symbol: "gearshape")
            item(String(localized: "Pomoc VoiceAI"), symbol: "questionmark.circle")
            item(String(localized: "Sprawdź aktualizacje…"))
            divider
            item(String(localized: "Zakończ VoiceAI"))
        }
        .padding(.vertical, 5)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.17).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 10)
    }

    private func item(_ text: String, symbol: String? = nil, dim: Bool = false, chevron: Bool = false,
                      checked: Bool = false, orange: Bool = false) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).opacity(checked ? 1 : 0).frame(width: 18)
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12))
                        .foregroundStyle(orange ? Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) : .white)
                } else {
                    Color.clear
                }
            }
            .frame(width: 20)
            Text(verbatim: text.count > 38 ? String(text.prefix(38)) + "…" : text).font(.system(size: 13))
                .lineLimit(1).fixedSize().padding(.leading, 6)
            Spacer(minLength: 8)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7)) }
        }
        .foregroundStyle(dim ? Color.white.opacity(0.45) : .white)
        .padding(.horizontal, 8).frame(height: 22)
    }
}

/// The word list as it opens in TextEdit: the sample list written the way VoiceAI writes the file.
private struct VocabularyPicture: View {
    static let lineHeight: CGFloat = 15

    private var lines: [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var vocabulary = HelpSample.vocabulary()
        vocabulary.aplikacje = ["com.apple.Terminal": AppRule(nazwa: "Terminal", kropka: false)]
        let data = (try? encoder.encode(vocabulary)) ?? Data()
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    private func line(of key: String) -> CGFloat {
        // Only the top-level key: an app rule has a "zamiany" of its own.
        CGFloat(lines.firstIndex { $0.hasPrefix("  \"\(key)\"") } ?? 0)
    }

    var body: some View {
        let top: CGFloat = 30 + 12
        Frame {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 11, height: 11) }
                    Spacer()
                    Text(verbatim: "slownik.json").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Color.clear.frame(width: 47, height: 1)
                }
                .padding(.horizontal, 12).frame(height: 30)
                .background(Color.primary.opacity(0.04))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, text in
                        Text(verbatim: text).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).fixedSize()
                            .frame(height: Self.lineHeight)
                    }
                }
                .padding(.leading, 44).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(["slowa", "zamiany", "aplikacje"].enumerated()), id: \.offset) { i, key in
                    Marker(number: i + 1).position(x: 22, y: top + line(of: key) * Self.lineHeight + Self.lineHeight / 2)
                }
            }
        }
    }
}

/// A recording dropped on VoiceAI, and the text and subtitles it leaves next to it.
private struct FilesPicture: View {
    private func file(_ ext: String, _ type: UTType) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(for: type)).resizable().frame(width: 64, height: 64)
            Text(verbatim: L(HelpContent.sampleFile) + "." + ext).font(.system(size: 12)).foregroundStyle(.white)
        }
    }

    var body: some View {
        Frame {
            ZStack {
                Desktop()
                VStack(spacing: 22) {
                    HStack(spacing: 18) {
                        file("m4a", .mpeg4Audio)
                        Image(systemName: "arrow.right").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    }
                    HStack(spacing: 30) {
                        file("txt", .plainText)
                        file("srt", UTType(filenameExtension: "srt") ?? .plainText)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.12)))
                }
            }
            .frame(width: 440, height: 290)
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Marker(number: 1).position(x: 318, y: 40)
                Marker(number: 2).position(x: 100, y: 170)
            }
        }
    }
}

/// The numbered point on a picture, and the same number in front of a step.
struct Marker: View {
    let number: Int
    var small = false

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: small ? 11 : 13, weight: .bold)).monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: small ? 20 : 26, height: small ? 20 : 26)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(.white, lineWidth: small ? 0 : 2))
            .shadow(color: .black.opacity(small ? 0 : 0.35), radius: 3, y: 1)
    }
}

/// Rounded card with a soft shadow — the frame every picture sits in.
struct Frame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// The Fractal 8 Dev signature at the end of Help, set like the hero of fractal8.eu: the logo large behind,
/// under the same veil as the site's video (darker at the edges and towards the bottom), and the text over
/// its lower part — "ENDLESS RECURSION" spaced 0.42 em in the accent (#7ee8f2 dark, #0a8796 light), then
/// "Fractal 8 Dev" in SF Pro Bold drawn together by −0.045 em with the site's gradient, then the site's line.
private struct FractalSignature: View {
    @Environment(\.colorScheme) private var scheme
    private static let logo: NSImage? = Bundle.main.url(forResource: "studio-logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        let dark = scheme == .dark
        let back = Color(nsColor: .windowBackgroundColor)
        let accent = dark ? Color(red: 126 / 255, green: 232 / 255, blue: 242 / 255) : Color(red: 10 / 255, green: 135 / 255, blue: 150 / 255)
        let gradient = LinearGradient(stops: [
            .init(color: dark ? .white : Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255), location: 0.4),
            .init(color: dark ? Color(red: 159 / 255, green: 163 / 255, blue: 171 / 255) : Color(red: 91 / 255, green: 95 / 255, blue: 102 / 255), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        ZStack(alignment: .bottom) {
            if let logo = Self.logo {
                Image(nsImage: logo).resizable().interpolation(.high).frame(width: 560, height: 560)
                    .opacity(dark ? 0.75 : 0.55)
                    .frame(height: 440, alignment: .top)
                    .clipped()
                    // The site's veil (styles.css, .hero-sticky::after): edges and the bottom sink into the background.
                    .overlay(RadialGradient(stops: [.init(color: .clear, location: 0.35), .init(color: back.opacity(0.75), location: 1)],
                                            center: .center, startRadius: 0, endRadius: 300))
                    .overlay(LinearGradient(stops: [.init(color: back.opacity(0.35), location: 0), .init(color: .clear, location: 0.3),
                                                    .init(color: back.opacity(0.55), location: 0.62), .init(color: back, location: 0.92)],
                                            startPoint: .top, endPoint: .bottom))
            }
            VStack(spacing: 0) {
                Text(verbatim: "ENDLESS RECURSION")
                    .font(.system(size: 12)).tracking(12 * 0.42).foregroundStyle(accent)
                    .padding(.bottom, 16)
                Text(verbatim: "Fractal 8 Dev")
                    .font(.system(size: 76, weight: .bold)).tracking(-76 * 0.045)
                    .foregroundStyle(gradient)
                Text(verbatim: L(HelpContent.signatureLine))
                    .font(.system(size: 17)).foregroundStyle(.secondary)
                    .padding(.top, 18)
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 440)
        .padding(.top, 40)
    }
}

// MARK: - Bitmap of the Help page, for checking it without opening a window

/// `VoiceAI --export-help <folder>` (language from `-AppleLanguages '(pl)'`): draws the Help page and the
/// window pictures into PNG files and quits. The app's normal start never runs: no model, no key watch,
/// no microphone, no menu bar icon, no window on screen, the user's settings untouched.
enum HelpExport {
    static func runIfRequested() {
        let a = CommandLine.arguments
        // `--export-help-window <folder>`: the Help window as the app shows it (pictures made the way `show()`
        // makes them, the page in a scroll view), to check what the user sees, not only the export.
        if let i = a.firstIndex(of: "--export-help-window"), i + 1 < a.count {
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                let folder = URL(fileURLWithPath: a[i + 1], isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let size = NSSize(width: HelpPage.width, height: 900)
                let host = NSHostingView(rootView: HelpPage(pictures: HelpPictures.make()))
                let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                host.frame = NSRect(origin: .zero, size: size)
                w.contentView = host
                w.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                save(Render.bitmap(host), folder.appendingPathComponent("help-window-\(Language.interface).png"))
            }
            exit(0)
        }
        guard let i = a.firstIndex(of: "--export-help"), i + 1 < a.count else { return }
        MainActor.assumeIsolated {
            let folder = URL(fileURLWithPath: a[i + 1], isDirectory: true)
            NSApplication.shared.setActivationPolicy(.prohibited)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let lang = Language.interface
            let p = HelpPictures.make()
            for (name, image) in [("settings", p.settings), ("journal", p.journal)] {
                save(image, folder.appendingPathComponent("window-\(name)-\(lang).png"))
            }
            let page = HelpPage(pictures: p, wholePage: true)
            // The height measured at the fixed width — `fittingSize` measures without it and cuts the top and bottom off.
            let h = NSHostingController(rootView: page)
                .sizeThatFits(in: CGSize(width: HelpPage.width, height: CGFloat.greatestFiniteMagnitude)).height
            save(Render.window(page, size: NSSize(width: HelpPage.width, height: ceil(h))), folder.appendingPathComponent("help-\(lang).png"))
        }
        exit(0)
    }

    private static func save(_ image: NSImage, _ url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        FileHandle.standardOutput.write(Data("\(url.path) \(Int(image.size.width))×\(Int(image.size.height))\n".utf8))
    }
}
