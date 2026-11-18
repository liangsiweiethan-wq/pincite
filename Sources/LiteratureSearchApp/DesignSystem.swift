import SwiftUI
import AppKit

/// Visual design system for the literature search app ("study room" design). Presentation-only:
/// spacing rhythm, corner radii, semantic colors, motion tokens, and small
/// shared components. Theme-aware colors resolve through
/// `DS.Color.palette(_:_:)` — the single entry dictated by the three-state
/// injection contract (docs/VISUAL-DESIGN.md). Nothing here
/// touches search, guard, or OCR-coordinate semantics.
enum DS {
    /// Spacing rhythm: 4 / 8 / 12 / 16 / 24 / 32 / 48.
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    /// Corner radii: 8 / 10 / 12 / 3 (seal).
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 10
        static let large: CGFloat = 12
        static let seal: CGFloat = 3
    }

    enum Layout {
        /// ReadingChrome wide ⇄ wrapped breakpoint (two-line contract).
        static let chromeWrapThreshold: CGFloat = 640
    }

    enum Motion {
        /// Default enter/exit transition length.
        static let duration: Double = 0.2
        /// Hover/selection state crossfade (stroke and tint swaps).
        static let hoverDuration: Double = 0.15
        /// Maximum enter translation (points).
        static let offset: CGFloat = 6
        /// The one enter animation every `.dsAppear` consumer shares.
        static var enter: Animation { .easeInOut(duration: duration) }
    }

    /// 增强对比度级别（对比度感知 token 层的取值域）。
    enum ContrastLevel {
        case normal
        case increased
    }

    /// Three-state theme (docs/VISUAL-DESIGN.md 表值注记 3): `system` follows the system
    /// appearance (aqua → 明/paper, darkAqua → 墨灰/graphite); `graphite` and
    /// `obsidian` are explicit user choices that ignore the system appearance.
    enum Theme: String, CaseIterable {
        case system, graphite, obsidian

        /// Effective color tier after resolving a system appearance.
        enum Tier: Hashable {
            case paper       // 明（纸）
            case graphite    // 墨灰（默认深灰）
            case obsidian    // 玄青（纯黑 OLED）
        }

        func resolved(scheme: ColorScheme) -> Tier {
            switch self {
            case .system: return scheme == .dark ? .graphite : .paper
            case .graphite: return .graphite
            case .obsidian: return .obsidian
            }
        }
    }

    /// Low-saturation academic palette. OCR amber is the one accent reserved
    /// for the OCR provenance signal — legal positions only: source badges,
    /// OCR status lines, preview-card tinting, and the book-spine stripe (OCR).
    enum Color {
        private static func adaptive(_ name: String, light: NSColor, dark: NSColor) -> SwiftUI.Color {
            SwiftUI.Color(NSColor(name: NSColor.Name(name), dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }))
        }

        /// OCR provenance amber (`accent-ocr`): source badge, OCR status line,
        /// preview-card tint, book spine (OCR). Nothing else.
        static let ocr = adaptive("ls.ocr",
                                  light: NSColor(srgbRed: 0.63, green: 0.36, blue: 0.12, alpha: 1),
                                  dark: NSColor(srgbRed: 0.86, green: 0.60, blue: 0.30, alpha: 1))

        /// Errors (stale reference, guard refusals, rejected citations).
        static let error = adaptive("ls.error",
                                    light: NSColor(srgbRed: 0.69, green: 0.16, blue: 0.14, alpha: 1),
                                    dark: NSColor(srgbRed: 0.95, green: 0.47, blue: 0.44, alpha: 1))

        /// Warnings (truncation, partial coverage, policy config notes).
        static let warning = adaptive("ls.warning",
                                      light: NSColor(srgbRed: 0.60, green: 0.42, blue: 0.05, alpha: 1),
                                      dark: NSColor(srgbRed: 0.88, green: 0.66, blue: 0.28, alpha: 1))

        /// Success (done steps, accepted citations, fully-covered books).
        static let success = adaptive("ls.success",
                                      light: NSColor(srgbRed: 0.21, green: 0.43, blue: 0.27, alpha: 1),
                                      dark: NSColor(srgbRed: 0.44, green: 0.73, blue: 0.52, alpha: 1))

        /// Informational blue-gray (zero-hit "no text layer" reasons).
        static let info = adaptive("ls.info",
                                   light: NSColor(srgbRed: 0.30, green: 0.38, blue: 0.49, alpha: 1),
                                   dark: NSColor(srgbRed: 0.62, green: 0.70, blue: 0.81, alpha: 1))

        /// Context base for `hex @N%` blends (docs/VISUAL-DESIGN.md 表值注记 1): strokes
        /// blend onto `paper`, window/page margins onto `desk`.
        enum OverlayBase { case paper, desk }

        /// Sole implementation of the table's `hex @N%` semantics: the pure
        /// `hex` at alpha N% pre-composited onto `base` — never a global
        /// opacity (which would show through whatever is behind).
        static func overlay(hex: String, alpha: Double, on base: NSColor) -> NSColor {
            let foreground = NSColor(srgbHex: hex) ?? .black
            guard alpha < 1,
                  let f = foreground.usingColorSpace(.sRGB),
                  let b = base.usingColorSpace(.sRGB) else { return foreground }
            let a = CGFloat(alpha)
            return NSColor(srgbRed: f.redComponent * a + b.redComponent * (1 - a),
                           green: f.greenComponent * a + b.greenComponent * (1 - a),
                           blue: f.blueComponent * a + b.blueComponent * (1 - a),
                           alpha: 1)
        }

        /// Per-tier resolved palette (见 docs/VISUAL-DESIGN.md 的完整色表).
        struct Palette {
            let paper: NSColor
            let desk: NSColor
            let ink: NSColor
            let inkSecondary: NSColor
            let inkSecondaryHighlight: NSColor
            let inkTertiary: NSColor
            let stroke: NSColor
            let strokeStrong: NSColor
            let select: NSColor
            let selectTint: NSColor
            let seal: NSColor
            let highlightNative: NSColor
            let highlightOCR: NSColor
            let ocr: NSColor
            let error: NSColor
            let warning: NSColor
            let success: NSColor
            let info: NSColor
        }

        private static let paperPalette = Palette(
            paper: NSColor(srgbHex: "#FBFAF7")!,
            desk: NSColor(srgbHex: "#F2F0EA")!,
            ink: NSColor(srgbHex: "#1F1C18")!,
            inkSecondary: NSColor(srgbHex: "#6E6A61")!,
            inkSecondaryHighlight: NSColor(srgbHex: "#4A463F")!,
            inkTertiary: NSColor(srgbHex: "#9A958A")!,
            stroke: overlay(hex: "#1F1C18", alpha: 0.10, on: NSColor(srgbHex: "#FBFAF7")!),
            strokeStrong: overlay(hex: "#1F1C18", alpha: 0.22, on: NSColor(srgbHex: "#FBFAF7")!),
            select: NSColor(srgbHex: "#566879")!,
            selectTint: overlay(hex: "#566879", alpha: 0.10, on: NSColor(srgbHex: "#FBFAF7")!),
            seal: NSColor(srgbHex: "#8A3220")!,
            highlightNative: NSColor(srgbHex: "#E8D48A")!,
            highlightOCR: NSColor(srgbHex: "#E4C08A")!,
            ocr: NSColor(srgbHex: "#A15C1F")!,
            error: NSColor(srgbHex: "#B02924")!,
            warning: NSColor(srgbHex: "#996B0D")!,
            success: NSColor(srgbHex: "#366E45")!,
            info: NSColor(srgbHex: "#4D617D")!)

        private static let graphitePalette = Palette(
            paper: NSColor(srgbHex: "#26272B")!,
            desk: NSColor(srgbHex: "#1B1C1F")!,
            ink: NSColor(srgbHex: "#E8E6E1")!,
            inkSecondary: NSColor(srgbHex: "#A8A59C")!,
            inkSecondaryHighlight: NSColor(srgbHex: "#CFCCC4")!,
            inkTertiary: NSColor(srgbHex: "#76736B")!,
            stroke: overlay(hex: "#FFFFFF", alpha: 0.10, on: NSColor(srgbHex: "#26272B")!),
            strokeStrong: overlay(hex: "#FFFFFF", alpha: 0.22, on: NSColor(srgbHex: "#26272B")!),
            select: NSColor(srgbHex: "#7F93A6")!,
            selectTint: overlay(hex: "#7F93A6", alpha: 0.16, on: NSColor(srgbHex: "#26272B")!),
            seal: NSColor(srgbHex: "#C4705C")!,
            highlightNative: NSColor(srgbHex: "#D8C67E")!,
            highlightOCR: NSColor(srgbHex: "#DDB57E")!,
            ocr: NSColor(srgbHex: "#DB994D")!,
            error: NSColor(srgbHex: "#F27870")!,
            warning: NSColor(srgbHex: "#E0A847")!,
            success: NSColor(srgbHex: "#70BA85")!,
            info: NSColor(srgbHex: "#9EB3CF")!)

        private static let obsidianPalette = Palette(
            paper: NSColor(srgbHex: "#141518")!,
            desk: NSColor(srgbHex: "#000000")!,
            ink: NSColor(srgbHex: "#ECEAE4")!,
            inkSecondary: NSColor(srgbHex: "#9B9890")!,
            inkSecondaryHighlight: NSColor(srgbHex: "#C6C3BB")!,
            inkTertiary: NSColor(srgbHex: "#6B6862")!,
            stroke: overlay(hex: "#FFFFFF", alpha: 0.12, on: NSColor(srgbHex: "#141518")!),
            strokeStrong: overlay(hex: "#FFFFFF", alpha: 0.26, on: NSColor(srgbHex: "#141518")!),
            select: NSColor(srgbHex: "#8799AC")!,
            selectTint: overlay(hex: "#8799AC", alpha: 0.18, on: NSColor(srgbHex: "#141518")!),
            seal: NSColor(srgbHex: "#CE7A66")!,
            highlightNative: NSColor(srgbHex: "#CDBB72")!,
            highlightOCR: NSColor(srgbHex: "#C8A86E")!,
            ocr: NSColor(srgbHex: "#E8A558")!,
            error: NSColor(srgbHex: "#FF8D84")!,
            warning: NSColor(srgbHex: "#EDB95C")!,
            success: NSColor(srgbHex: "#82CB98")!,
            info: NSColor(srgbHex: "#AEC2DE")!)

        private static let palettes: [DS.Theme.Tier: Palette] = [
            .paper: paperPalette, .graphite: graphitePalette, .obsidian: obsidianPalette,
        ]

        /// Single resolution entry for every three-state color (主题注入约定).
        static func palette(_ theme: DS.Theme, _ scheme: ColorScheme) -> Palette {
            palettes[theme.resolved(scheme: scheme)] ?? paperPalette
        }

        static func paper(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).paper)
        }
        static func desk(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).desk)
        }
        static func ink(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).ink)
        }
        /// 增强对比度变体：ink 主 token 拉向纯黑/纯白端（相对亮度
        /// 单调极化，对比度不低于普通变体；精确比值由检查工具校验。
        static func ink(_ theme: DS.Theme, _ scheme: ColorScheme,
                        _ contrast: DS.ContrastLevel) -> SwiftUI.Color {
            contrast == .normal
                ? SwiftUI.Color(palette(theme, scheme).ink)
                : adaptive("ls.ink.hc",
                           light: .black,
                           dark: .white)
        }
        static func inkSecondary(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).inkSecondary)
        }
        /// 增强对比度变体：次级文字向极化端收紧（浅色更深、深色更亮）。
        static func inkSecondary(_ theme: DS.Theme, _ scheme: ColorScheme,
                                 _ contrast: DS.ContrastLevel) -> SwiftUI.Color {
            contrast == .normal
                ? SwiftUI.Color(palette(theme, scheme).inkSecondary)
                : adaptive("ls.inkSecondary.hc",
                           light: NSColor(srgbHex: "#2E2A24")!,
                           dark: NSColor(srgbHex: "#F2EFE9")!)
        }
        static func inkSecondaryHighlight(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).inkSecondaryHighlight)
        }
        static func inkTertiary(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).inkTertiary)
        }
        /// 增强对比度变体：三级文字原对比最弱（light 端 ≈3:1），
        /// 高对比下收紧到次级文字量级以上。
        static func inkTertiary(_ theme: DS.Theme, _ scheme: ColorScheme,
                                _ contrast: DS.ContrastLevel) -> SwiftUI.Color {
            contrast == .normal
                ? SwiftUI.Color(palette(theme, scheme).inkTertiary)
                : adaptive("ls.inkTertiary.hc",
                           light: NSColor(srgbHex: "#514C42")!,
                           dark: NSColor(srgbHex: "#D8D4CB")!)
        }
        static func stroke(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).stroke)
        }
        /// 增强对比度变体：描边在增强对比下加深 alpha（hairline
        /// 结构线仍 1px，不增粗）。
        static func stroke(_ theme: DS.Theme, _ scheme: ColorScheme,
                           _ contrast: DS.ContrastLevel) -> SwiftUI.Color {
            contrast == .normal
                ? SwiftUI.Color(palette(theme, scheme).stroke)
                : adaptive("ls.stroke.hc",
                           light: overlay(hex: "#1F1C18", alpha: 0.30, on: NSColor(srgbHex: "#FBFAF7")!),
                           dark: overlay(hex: "#ECE9E2", alpha: 0.34, on: NSColor(srgbHex: "#3A3733")!))
        }
        static func strokeStrong(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).strokeStrong)
        }
        /// 增强对比度变体。
        static func strokeStrong(_ theme: DS.Theme, _ scheme: ColorScheme,
                                 _ contrast: DS.ContrastLevel) -> SwiftUI.Color {
            contrast == .normal
                ? SwiftUI.Color(palette(theme, scheme).strokeStrong)
                : adaptive("ls.strokeStrong.hc",
                           light: overlay(hex: "#1F1C18", alpha: 0.48, on: NSColor(srgbHex: "#FBFAF7")!),
                           dark: overlay(hex: "#ECE9E2", alpha: 0.60, on: NSColor(srgbHex: "#3A3733")!))
        }
        /// 石板灰蓝（降饱和）：仅选中态与可点链接，不作装饰 accent。
        static func select(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).select)
        }
        static func selectTint(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).selectTint)
        }
        /// 印章点缀专用（方形小印/统计牌角标/空态刻痕），全应用限品牌触点。
        static func seal(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).seal)
        }

        static func ocr(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).ocr)
        }
        static func error(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).error)
        }
        static func warning(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).warning)
        }
        static func success(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).success)
        }
        static func info(_ theme: DS.Theme, _ scheme: ColorScheme) -> SwiftUI.Color {
            SwiftUI.Color(palette(theme, scheme).info)
        }

        /// PDF highlight colors as NSColor (PDFAnnotation layer). The page
        /// itself is never inverted; these are drawn on the original page.
        static func highlightNative(_ theme: DS.Theme, _ scheme: ColorScheme) -> NSColor {
            palette(theme, scheme).highlightNative
        }
        static func highlightOCR(_ theme: DS.Theme, _ scheme: ColorScheme) -> NSColor {
            palette(theme, scheme).highlightOCR
        }

        /// Vibrancy material for floating chrome (`surface` token): obsidian
        /// drops to ultraThin so pure black does not turn the layer grey.
        static func surface(_ theme: DS.Theme) -> Material {
            theme == .obsidian ? .ultraThinMaterial : .regularMaterial
        }

        /// Status → color, single source of truth (stat plates, coverage dots,
        /// badges all consume this to prevent mapping drift).
        enum Status {
            case success, warning, ocr, neutral
        }
        static func forStatus(_ status: Status, theme: DS.Theme, scheme: ColorScheme) -> SwiftUI.Color {
            switch status {
            case .success: return success(theme, scheme)
            case .warning: return warning(theme, scheme)
            case .ocr: return ocr(theme, scheme)
            case .neutral: return inkSecondary(theme, scheme)
            }
        }
    }

    enum Font {
        private static let songtiAvailable = NSFont(name: "Songti SC", size: 15) != nil
        private static let songtiBoldAvailable = NSFont(name: "Songti SC Bold", size: 15) != nil

        static func readingSerif(size: CGFloat = 15) -> SwiftUI.Font {
            if songtiAvailable, let font = NSFont(name: "Songti SC", size: size) {
                return SwiftUI.Font(font)
            }
            return SwiftUI.Font(NSFont.systemFont(ofSize: size))
        }
        /// 宋体引注行下限 12.5pt（docs/VISUAL-DESIGN.md clreq 细则 4：不得再降）。
        static var readingSerifMeta: SwiftUI.Font { readingSerif(size: 12.5) }

        /// Display serif for headings: Songti SC Bold → Songti SC → system
        static func displaySerif(size: CGFloat) -> SwiftUI.Font {
            if songtiBoldAvailable, let font = NSFont(name: "Songti SC Bold", size: size) {
                return SwiftUI.Font(font)
            }
            if songtiAvailable, let font = NSFont(name: "Songti SC", size: size) {
                return SwiftUI.Font(font)
            }
            return SwiftUI.Font.system(size: size, weight: .semibold, design: .serif)
        }
        /// 页面大标题（覆盖/历史/书库页头、关于页）。
        static var displayPage: SwiftUI.Font { displaySerif(size: 24) }
        /// 空态大标题。
        static var displayEmpty: SwiftUI.Font { displaySerif(size: 20) }
        /// 组头/内容标题（结果组头书名、查询词）。
        static var displayGroup: SwiftUI.Font { displaySerif(size: 17) }
        /// 区块头（设置/详情小节标题）。
        static var displaySection: SwiftUI.Font { displaySerif(size: 13) }
    }
}

extension DS.Theme {
    /// Lossless decode of the `@AppStorage("dsTheme")` raw value.
    static func storage(_ rawValue: String) -> DS.Theme {
        DS.Theme(rawValue: rawValue) ?? .system
    }
}


/// Environment key carrying the resolved three-state theme (contract):
/// RootView injects the same value that drives `.id(dsTheme)` rebuilds, so
/// child views read `@Environment(\.dsTheme)` instead of duplicating the
/// `@AppStorage("dsTheme") + @Environment(\.colorScheme)` boilerplate. This
/// only carries the theme value — `DS.Color.resolve` remains the sole color
/// resolution entry.
struct DSThemeKey: EnvironmentKey {
    static let defaultValue: DS.Theme = .system
}

extension EnvironmentValues {
    var dsTheme: DS.Theme {
        get { self[DSThemeKey.self] }
        set { self[DSThemeKey.self] = newValue }
    }
}

extension NSColor {
    /// "#RRGGBB" → sRGB color; anything else returns nil.
    convenience init?(srgbHex: String) {
        var hex = srgbHex
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Shared components

/// Small capsule badge: semantic-colored text on a 12% tint of the same
/// color. The single badge style for source labels, match counts, and
struct CapsuleBadge: View {
    let text: String
    let color: SwiftUI.Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Icon-led status line (indexing progress, truncation, errors, OCR hints).
struct StatusRow: View {
    let systemImage: String
    let text: String
    let color: SwiftUI.Color
    var font: Font = .caption

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(color)
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Centered empty-state composition: large SF Symbol (30pt, ink-tertiary),
/// serif headline with a seal-red underscore bar (brand touch),
/// and an auxiliary line. Fades in with a 6pt rise (DS.Motion). Used for the
/// not-searched-yet state, empty history, and the detail pane placeholder.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var detail: String? = nil

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    @State private var appeared = false

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            VStack(spacing: DS.Spacing.xs) {
                Text(title)
                    .font(DS.Font.displayEmpty)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                Rectangle()
                    .fill(DS.Color.seal(theme, scheme))
                    .frame(width: 24, height: 2)
            }
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : DS.Motion.offset)
        .onAppear {
            withAnimation(reduceMotion ? nil : DS.Motion.enter) { appeared = true }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.xxl)
    }
}

struct DSAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : DS.Motion.offset)
            .onAppear {
                withAnimation(reduceMotion ? nil : DS.Motion.enter) { appeared = true }
            }
    }
}

extension View {
    func dsAppear() -> some View {
        modifier(DSAppear())
    }
}

/// Paper card: solid `paper` fill + 1px `stroke` hairline. Hover (and the
/// `active` state) deepen the stroke to `strokeStrong` with a 0.15s crossfade
/// (motion language); no shadow, no fill change. Card padding 12 → 16
/// (留白专项). The default surface for every paper scenario (hit cards,
/// reason cards, stat plates, citation panels, book cards, step cards).
struct PaperCard: ViewModifier {
    var radius: CGFloat = DS.Radius.large
    var active: Bool = false
    var hoverable: Bool = true

    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let theme = DS.Theme.storage(dsTheme)
        let palette = DS.Color.palette(theme, scheme)
        let strokeColor = (active || isHovered) ? palette.strokeStrong : palette.stroke
        return content
            .padding(DS.Spacing.md)
            .background(SwiftUI.Color(palette.paper), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .stroke(SwiftUI.Color(strokeColor), lineWidth: 1))
            .animation(.easeInOut(duration: DS.Motion.hoverDuration), value: isHovered)
            .onHover { hovering in
                if hoverable { isHovered = hovering }
            }
    }
}

extension View {
    func paperCard(radius: CGFloat = DS.Radius.large, active: Bool = false) -> some View {
        modifier(PaperCard(radius: radius, active: active))
    }
}

/// Layered vibrancy card: material + 1px hairline stroke. Reserved for
/// floating/material scenarios only (preview-card style layers); paper
/// scenarios always use `PaperCard`.
struct CardSurface: ViewModifier {
    var radius: CGFloat = DS.Radius.large
    var material: Material = .regularMaterial

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dsTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(DS.Spacing.md)
            .background(material, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
    }
}

extension View {
    func cardSurface(radius: CGFloat = DS.Radius.large, material: Material = .regularMaterial) -> some View {
        modifier(CardSurface(radius: radius, material: material))
    }
}

/// Token-ized text field (走查): `paper` fill + `stroke` 1px hairline +
/// `Radius.medium`, replacing the system `.roundedBorder` gray box in every
/// internal panel. Fields embedded in material chrome that must stay
/// weightless (command-palette header) keep `.plain`.
struct DSTextFieldStyle: TextFieldStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dsTheme) private var theme

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs)
            .background(DS.Color.paper(theme, scheme),
                        in: RoundedRectangle(cornerRadius: DS.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
                .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
    }
}

extension TextFieldStyle where Self == DSTextFieldStyle {
    static var dsTextField: DSTextFieldStyle { DSTextFieldStyle() }
}

struct Hairline: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dsTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(DS.Color.stroke(theme, scheme).opacity(0.6))
            .frame(height: 1)
    }
}

extension View {
    /// Edge-aligned hairline separator (default: bottom).
    func dsHairline(edge: VerticalEdge = .bottom) -> some View {
        overlay(alignment: edge == .bottom ? .bottom : .top) { Hairline() }
    }
}

/// hover feedback for plain interactive rows: opacity 1.0 → 0.85 over
/// 0.15s (DS.Motion.hoverDuration). No spring, no scale — 克制但有生命.
struct DSHoverFade: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .opacity(isHovered ? 0.85 : 1.0)
            .animation(.easeOut(duration: DS.Motion.hoverDuration), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    func dsHoverFade() -> some View {
        modifier(DSHoverFade())
    }
}

/// Square seal accent (方形小印): 10×10, `seal` corner radius 3, 1px seal
/// stroke (hollow) or solid fill. Legal spots: library section headers,
/// the stat-plate corner mark, and the empty-state underscore bar
/// (EmptyStateView, brand touch).
struct SealBadge: View {
    var filled: Bool = false

    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    var body: some View {
        let seal = DS.Color.seal(.storage(dsTheme), scheme)
        RoundedRectangle(cornerRadius: DS.Radius.seal)
            .fill(filled ? seal : .clear)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.seal)
                .stroke(seal, lineWidth: 1))
            .frame(width: 10, height: 10)
    }
}

/// Stat plate (统计牌): paper card with a semantic dot, `title`-weight
/// monospaced value and a caption label. The whole plate is the Button —
/// never a bare tap gesture.
struct StatPlate: View {
    let value: String
    let label: String
    var status: DS.Color.Status = .neutral
    var isActive: Bool = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        Button(action: action) {
            HStack(spacing: DS.Spacing.xs) {
                Circle()
                    .fill(DS.Color.forStatus(status, theme: theme, scheme: scheme))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(value)
                        .font(.headline)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.ink(theme, scheme))
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .paperCard(radius: DS.Radius.medium, active: isActive)
    }
}

/// Citation line (版权页行): `micro` + ink-tertiary, one line, with a
/// trailing fade mask that engages only when the text actually exceeds the
/// available width (functional truncation — the single sanctioned use of a
/// fade, docs/VISUAL-DESIGN.md Don't 7).
struct CitationLine: View {
    let text: String
    var font: Font = .caption2

    /// Both geometry probes report into this one value (one preference pass
    /// per layout instead of two): `natural` feeds the over-threshold test,
    /// `available` feeds both the mask width and the threshold itself.
    @State private var metrics = Metrics()
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(DS.Color.inkTertiary(.storage(dsTheme), scheme))
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { proxy in
                Color.clear.preference(key: GeometryKey.self,
                                       value: Metrics(natural: proxy.size.width))
            })
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask(fadeMask)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: GeometryKey.self,
                                       value: Metrics(available: proxy.size.width))
            })
            .onPreferenceChange(GeometryKey.self) { metrics = $0 }
    }

    @ViewBuilder
    private var fadeMask: some View {
        if metrics.natural > metrics.available + 1 {
            LinearGradient(colors: [.black, .black, .clear],
                           startPoint: .leading, endPoint: .trailing)
        } else {
            Color.black
        }
    }

    private struct Metrics: Equatable {
        var natural: CGFloat = 0
        var available: CGFloat = .infinity
    }
    private struct GeometryKey: PreferenceKey {
        static let defaultValue = Metrics()
        static func reduce(value: inout Metrics, nextValue: () -> Metrics) {
            let next = nextValue()
            if next.natural != 0 { value.natural = next.natural }
            if next.available != .infinity { value.available = next.available }
        }
    }
}

/// Book spine stripe (书脊条): 2pt-wide full-height bar on the row's leading
/// edge carrying the source semantics (native → ink, OCR → accent-ocr). Amber
/// here is a legal position: the stripe sits beside the book title and its
/// verifiable citation + page counts.
struct BookSpine: ViewModifier {
    let source: String

    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    func body(content: Content) -> some View {
        let theme = DS.Theme.storage(dsTheme)
        return content.overlay(alignment: .leading) {
            Rectangle()
                .fill(source == "ocr"
                      ? DS.Color.ocr(theme, scheme)
                      : DS.Color.ink(theme, scheme))
                .frame(width: 2)
        }
    }
}

extension View {
    func bookSpine(source: String) -> some View {
        modifier(BookSpine(source: source))
    }
}

// MARK: - 增强对比度：双通道信号与环境注入
//
// 通道一：SwiftUI `@Environment(\.colorSchemeContrast)`（macOS 13 编译可用）。
// 通道二：AppKit `NSWorkspace.accessibilityDisplayShouldIncreaseContrast`
// KVO 监视器（macOS 运行时的可靠信号源）。两者取或——任一报告增强对比，
// token 即切高对比变体。守卫 (b)（DesignGuardSuite）断言本文件含
// colorSchemeContrast 存在性。

import Combine

/// NSWorkspace 增强对比 KVO 监视器（@MainActor；KVO 回调切主线程发布）。
@MainActor
final class DSContrastMonitor: ObservableObject {
    static let shared = DSContrastMonitor()
    @Published private(set) var increased: Bool

    private var observation: NSKeyValueObservation?

    private init() {
        increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        observation = NSWorkspace.shared.observe(
            \.accessibilityDisplayShouldIncreaseContrast, options: [.initial, .new]
        ) { [weak self] _, change in
            let newValue = change.newValue
                ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            Task { @MainActor in
                self?.increased = newValue
            }
        }
    }

    deinit {
        observation?.invalidate()
    }
}

private struct DSIncreasedContrastKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 增强对比生效态（视图层读它给 DS.Color 高对比变体传参）。
    var dsIncreasedContrast: Bool {
        get { self[DSIncreasedContrastKey.self] }
        set { self[DSIncreasedContrastKey.self] = newValue }
    }
}

/// 视图根部调用一次：合成 SwiftUI 环境与 AppKit KVO 两路信号写入 DS 环境键。
struct DSContrastInjection: ViewModifier {
    @Environment(\.colorSchemeContrast) private var environmentContrast
    @ObservedObject private var monitor = DSContrastMonitor.shared

    func body(content: Content) -> some View {
        let increased = environmentContrast == .increased || monitor.increased
        return content.environment(\.dsIncreasedContrast, increased)
    }
}

extension View {
    func dsContrastInjection() -> some View {
        modifier(DSContrastInjection())
    }
}

/// 便捷读取：局部视图内取 DS 对比度级别（给 DS.Color 高对比重载传参）。
struct DSContrastReader: ViewModifier {
    @Environment(\.dsIncreasedContrast) private var increased
    @Environment(\.colorSchemeContrast) private var environmentContrast
    @ObservedObject private var monitor = DSContrastMonitor.shared

    func body(content: Content) -> some View {
        let level: DS.ContrastLevel = (increased || environmentContrast == .increased
                                       || monitor.increased) ? .increased : .normal
        return content.environment(\.dsContrastLevel, level)
    }
}

private struct DSContrastLevelKey: EnvironmentKey {
    static let defaultValue = DS.ContrastLevel.normal
}

extension EnvironmentValues {
    var dsContrastLevel: DS.ContrastLevel {
        get { self[DSContrastLevelKey.self] }
        set { self[DSContrastLevelKey.self] = newValue }
    }
}
