import ActivityKit
import SwiftUI
import WidgetKit

struct TigerDuckLiveActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TigerDuckActivityAttributes.self) { context in
            LockScreenView(snapshot: context.state.snapshot)
                .activityBackgroundTint(hexColor(context.state.snapshot.accentHex).opacity(0.12))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let snapshot = context.state.snapshot
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: iconName(for: snapshot.scenario))
                        .font(.title3)
                        .foregroundStyle(hexColor(snapshot.accentHex))
                        .frame(width: 36, height: 36)
                        .background(hexColor(snapshot.accentHex).opacity(0.18), in: Circle())
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        countdownLabel(snapshot)
                            .font(.title2.monospacedDigit().bold())
                            .foregroundStyle(hexColor(snapshot.accentHex))
                        Text(countdownCaption(for: snapshot.scenario))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.title)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(snapshot.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let loc = snapshot.locationText, !loc.isEmpty {
                                Text("·")
                                    .foregroundStyle(.secondary)
                                Label(loc, systemImage: "mappin.and.ellipse")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: iconName(for: snapshot.scenario))
                    .foregroundStyle(hexColor(snapshot.accentHex))
            } compactTrailing: {
                countdownLabel(snapshot)
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(hexColor(snapshot.accentHex))
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: iconName(for: snapshot.scenario))
                    .font(.title2.bold())
                    .foregroundStyle(hexColor(snapshot.accentHex))
                    .frame(width: 48, height: 48)
                    .background(hexColor(snapshot.accentHex).opacity(0.18), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.title)
                        .font(.title3.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(snapshot.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let loc = snapshot.locationText, !loc.isEmpty {
                        Label(loc, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    countdownLabel(snapshot)
                        .font(.largeTitle.monospacedDigit().bold())
                        .foregroundStyle(hexColor(snapshot.accentHex))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(countdownCaption(for: snapshot.scenario))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = snapshot.progress {
                ProgressView(value: progress)
                    .tint(hexColor(snapshot.accentHex))
                    .scaleEffect(x: 1, y: 1.4, anchor: .center)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
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
