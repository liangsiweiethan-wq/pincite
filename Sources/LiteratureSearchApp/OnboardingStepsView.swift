import SwiftUI
import LiteratureCore
import LiteratureSearchUI

/// Empty state A: three-step onboarding (choose folder → index → search)
/// presented as one centered, width-limited material card.
/// Step 1 done when a root is chosen; step 2 runs/cancels indexing with
/// inline progress; step 3 is guidance only.
struct OnboardingStepsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        return VStack {
            Spacer()
            // 留白：卡片内区块间距 16 → 24。
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(L10n.onboardingTitle).font(DS.Font.displayPage)
                    Text(L10n.onboardingWelcome)
                        .font(.callout)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
                stepRow(number: 1, title: L10n.onboardingStep1, hint: L10n.onboardingStep1Hint,
                        done: state.rootName != nil) {
                    Button(L10n.chooseFolder) { state.chooseFolder() }
                        .buttonStyle(.bordered)
                }
                stepRow(number: 2, title: L10n.onboardingStep2, hint: L10n.onboardingStep2Hint,
                        done: (state.coverageStats?.booksOK ?? 0) > 0) {
                    if state.indexing {
                        Button(L10n.cancelIndexing) { state.cancelIndexing() }
                            .buttonStyle(.bordered)
                    } else {
                        Button(L10n.startIndexing) { state.startIndexing() }
                            .buttonStyle(.bordered)
                            .disabled(state.rootName == nil)
                    }
                }
                if state.indexing, let p = state.progress {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        ProgressView(value: p.filesTotal > 0 ? Double(p.filesDone) / Double(p.filesTotal) : 0)
                        Text("\(p.filesDone)/\(p.filesTotal)\(p.currentFile.map { " · \($0)" } ?? "")")
                            .font(.caption2)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                            .lineLimit(1)
                    }
                    .padding(.leading, DS.Spacing.xxl)
                }
                stepRow(number: 3, title: L10n.onboardingStep3, hint: L10n.onboardingStep3Hint,
                        done: state.searchedOnce) {
                    EmptyView()
                }
            }
            .paperCard(radius: DS.Radius.large)
            .frame(maxWidth: 560)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func stepRow<Trailing: View>(number: Int, title: String, hint: String,
                                         done: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        let theme = DS.Theme.storage(dsTheme)
        return HStack(alignment: .top, spacing: DS.Spacing.sm) {
            ZStack {
                if done {
                    RoundedRectangle(cornerRadius: DS.Radius.seal)
                        .fill(DS.Color.success(theme, scheme).opacity(0.15))
                        .frame(width: 24, height: 24)
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(DS.Color.success(theme, scheme))
                        // 完成勾有状态语义。
                        .accessibilityLabel(L10n.stepDoneBadge)
                } else {
                    HStack(spacing: DS.Spacing.xxs) {
                        RoundedRectangle(cornerRadius: DS.Radius.seal)
                            .stroke(DS.Color.inkTertiary(theme, scheme), lineWidth: 1)
                            .frame(width: 10, height: 10)
                        Text("\(number)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                    }
                }
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.sm) {
                    Text(title).font(DS.Font.displayGroup)
                    Spacer(minLength: DS.Spacing.xs)
                    trailing()
                }
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsAppear()
    }
}

/// Empty state A′ (错误恢复): a root is selected but the last index run
/// failed. Replaces the 3-step onboarding with the error line (existing
/// status idiom), a retry button on the existing start-indexing path, and
/// the originals-untouched note. startIndexing clears indexError, so a
/// retry flips this view back to the onboarding card with live progress.
struct IndexErrorRecoveryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        return VStack {
            Spacer()
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text(L10n.indexRetryTitle).font(DS.Font.displayGroup)
                if let error = state.indexError {
                    StatusRow(systemImage: "exclamationmark.circle.fill",
                              text: error, color: DS.Color.error(theme, scheme))
                }
                Button(L10n.indexRetryButton) { state.startIndexing() }
                    .buttonStyle(.bordered)
                    .disabled(state.indexing)
                Text(L10n.indexRetryNote)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .paperCard(radius: DS.Radius.large)
            .frame(maxWidth: 560)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
