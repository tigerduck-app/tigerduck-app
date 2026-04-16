import ActivityKit
import SwiftUI
import WidgetKit

struct TigerDuckLiveActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TigerDuckActivityAttributes.self) { context in
            LockScreenView(snapshot: context.state.snapshot)
                .activityBackgroundTint(hexColor(context.state.snapshot.accentHex).opacity(0.15))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let snapshot = context.state.snapshot
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: iconName(for: snapshot.scenario))
                            .foregroundStyle(hexColor(snapshot.accentHex))
                        Text(snapshot.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdownLabel(snapshot)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        if let loc = snapshot.locationText, !loc.isEmpty {
                            Label(loc, systemImage: "mappin.and.ellipse")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(snapshot.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: iconName(for: snapshot.scenario))
                    .foregroundStyle(hexColor(snapshot.accentHex))
            } compactTrailing: {
                countdownLabel(snapshot)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: iconName(for: snapshot.scenario))
                    .foregroundStyle(hexColor(snapshot.accentHex))
            }
            .widgetURL(snapshot.deepLink)
            .keylineTint(hexColor(snapshot.accentHex))
        }
    }
}

// MARK: - Lock screen layout

private struct LockScreenView: View {
    let snapshot: LiveActivitySnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName(for: snapshot.scenario))
                .font(.title2)
                .foregroundStyle(hexColor(snapshot.accentHex))
                .frame(width: 40, height: 40)
                .background(hexColor(snapshot.accentHex).opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(snapshot.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let loc = snapshot.locationText, !loc.isEmpty {
                    Label(loc, systemImage: "mappin.and.ellipse")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                countdownLabel(snapshot)
                    .font(.title3.monospacedDigit().bold())
                if let progress = snapshot.progress {
                    ProgressView(value: progress)
                        .frame(width: 72)
                        .tint(hexColor(snapshot.accentHex))
                } else {
                    Text(countdownCaption(for: snapshot.scenario))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - File-scope helpers (shared by lock screen + dynamic island)

private func iconName(for scenario: LiveActivityScenarioKind) -> String {
    switch scenario {
    case .inClass: return "graduationcap.fill"
    case .classPreparing: return "clock.arrow.circlepath"
    case .assignmentUrgent: return "doc.text.fill"
    }
}

private func countdownCaption(for scenario: LiveActivityScenarioKind) -> String {
    switch scenario {
    case .inClass: return "下課倒數"
    case .classPreparing: return "上課倒數"
    case .assignmentUrgent: return "截止倒數"
    }
}

@ViewBuilder
private func countdownLabel(_ snapshot: LiveActivitySnapshot) -> some View {
    if let target = snapshot.countdownTarget {
        let upper = max(target, Date())
        Text(timerInterval: Date()...upper, countsDown: true)
    } else {
        Text("—")
    }
}

/// Local helper (named `hexColor` not `accentColor` to avoid clashing with
/// the deprecated `View.accentColor(_:)` modifier during overload resolution).
private func hexColor(_ hex: Int) -> Color {
    let r = Double((hex >> 16) & 0xFF) / 255.0
    let g = Double((hex >> 8) & 0xFF) / 255.0
    let b = Double(hex & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}
