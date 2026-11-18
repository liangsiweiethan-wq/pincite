import SwiftUI
import LiteratureCore
import LiteratureSearchUI

/// Zero-hit is an answer, not an error: centered composition with the summary
/// prominent and per-book reasons as quiet rows. "No text layer" rows link to
/// the coverage page for the full picture. Reason text still comes verbatim
/// from HitRouter.zeroHitLines — only presentation (dot color + hierarchy) is
/// decided here.
struct ZeroHitView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    private var theme: DS.Theme { .storage(dsTheme) }

    var body: some View {
        let theme = self.theme
        // 留白：区块间距 12 → 24。
        VStack(spacing: DS.Spacing.lg) {
            if let z = state.zeroHitExplanation {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                Text(z.summary)
                    .font(DS.Font.displayPage)
                    .foregroundStyle(DS.Color.ocr(theme, scheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle()
                    .fill(DS.Color.seal(theme, scheme))
                    .frame(width: 24, height: 2)

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    ForEach(Array(HitRouter.zeroHitLines(z).dropFirst().enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: DS.Spacing.xs) {
                            Circle()
                                .fill(reasonColor(for: line))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .paperCard(radius: DS.Radius.large)
                .dsAppear()

                HStack(spacing: DS.Spacing.sm) {
                    Button(L10n.zeroHitRetry) {
                        // Same focus mechanism as ⌘F: SearchView observes the
                        // counter and focuses the search field.
                        state.focusSearchRequest += 1
                    }
                    .buttonStyle(.bordered)
                    Button(L10n.zeroHitCoverageLink) {
                        state.sidebarSection = .coverage
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.lg)
    }

    /// Reason-dot color matched on the fixed reason phrases HitRouter emits
    /// (purely presentational; the line text is untouched).
    private func reasonColor(for line: String) -> Color {
        if line.contains("无文字层") { return DS.Color.info(theme, scheme) }
        if line.contains("无法评估") { return DS.Color.warning(theme, scheme) }
        return DS.Color.inkSecondary(theme, scheme)
    }
}
