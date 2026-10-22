import ActivityKit
import SwiftUI
import WidgetKit

struct TigerDuckLiveActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TigerDuckActivityAttributes.self) { context in
            LockScreenView(snapshot: context.state.snapshot)
                .activityBackgroundTint(hexColor(context.state.snapshot.accentHex).opacity(0.12))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(context.state.snapshot.deepLink)
        } dynamicIsland: { context in
            let snapshot = context.state.snapshot
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hexColor(snapshot.accentHex))
                            .frame(width: 8, height: 8)
                        Text(statusLabel(for: snapshot.scenario))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        countdownLabel(snapshot)
                            .font(.footnote.monospacedDigit().bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(snapshot: snapshot)
                }
            } compactLeading: {
                if let loc = snapshot.locationText, !loc.isEmpty {
                    Text(loc)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hexColor(snapshot.accentHex))
                        .lineLimit(1)
                } else {
                    scenarioIcon(snapshot)
                }
            } compactTrailing: {
                countdownLabel(snapshot)
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(hexColor(snapshot.accentHex))
                    .frame(width: 60, alignment: .leading)
            } minimal: {
                scenarioIcon(snapshot)
            }
            .widgetURL(snapshot.deepLink)
            .keylineTint(hexColor(snapshot.accentHex))
        }
    }
}

private struct LockScreenView: View {
    let snapshot: LiveActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(hexColor(snapshot.accentHex))
                        .frame(width: 8, height: 8)
                    Text(statusLabel(for: snapshot.scenario))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Spacer(minLength: 12)

                countdownLabel(snapshot)
                    .font(.footnote.monospacedDigit().bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
            .frame(maxWidth: .infinity)

            Text(snapshot.title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)

            AutoProgressBar(snapshot: snapshot)

            MetadataRowView(snapshot: snapshot)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExpandedBottomView: View {
    let snapshot: LiveActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)

            AutoProgressBar(snapshot: snapshot)

            MetadataRowView(snapshot: snapshot)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

private struct AutoProgressBar: View {
    let snapshot: LiveActivitySnapshot

    var body: some View {
        if let start = snapshot.progressStart,
           let target = snapshot.countdownTarget,
           start < target {
            let realStart = AppClock.realTime(forApp: start)
            let realTarget = AppClock.realTime(forApp: target)
            ProgressView(timerInterval: realStart...realTarget, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(hexColor(snapshot.accentHex))
            .scaleEffect(x: 1, y: 1.2, anchor: .center)
            .padding(.vertical, 6)
        }
    }
}

private struct MetadataRowView: View {
    let snapshot: LiveActivitySnapshot

    var body: some View {
        HStack(spacing: 0) {
            switch snapshot.scenario {
            case .assignmentUrgent:
                HStack(spacing: 4) {
                    if !snapshot.subtitle.isEmpty {
                        Image(systemName: "text.book.closed.fill")
                        Text(snapshot.subtitle)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    if let ins = snapshot.instructor, !ins.isEmpty {
                        Image(systemName: "person.fill")
                        Text(ins)
                    }
                }

            case .inClass, .classPreparing:
                let hasLocation = snapshot.locationText?.isEmpty == false

                if hasLocation {
                    HStack(spacing: 4) {
                        if let loc = snapshot.locationText {
                            Image(systemName: "mappin.and.ellipse")
                            Text(loc)
                        }
                    }

                    Spacer(minLength: 8)
                }

                HStack(spacing: 4) {
                    if !snapshot.subtitle.isEmpty {
                        Image(systemName: "clock.fill")
                        Text(snapshot.subtitle)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    if let ins = snapshot.instructor, !ins.isEmpty {
                        Image(systemName: "person.fill")
                        Text(ins)
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }
}

@ViewBuilder
private func scenarioIcon(_ snapshot: LiveActivitySnapshot) -> some View {
    switch snapshot.scenario {
    case .inClass:
        Image("AppLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 20)
    case .classPreparing, .assignmentUrgent:
        Image(systemName: iconName(for: snapshot.scenario))
            .foregroundStyle(hexColor(snapshot.accentHex))
    }
}

private func iconName(for scenario: LiveActivityScenarioKind) -> String {
    switch scenario {
    case .inClass: return "graduationcap.fill"
    case .classPreparing: return "clock.arrow.circlepath"
    case .assignmentUrgent: return "doc.text.fill"
    }
}

private func statusLabel(for scenario: LiveActivityScenarioKind) -> String {
    switch scenario {
    case .inClass: return String(localized: "live_activity_status_in_class_short")
    case .classPreparing: return String(localized: "live_activity_status_class_preparing")
    case .assignmentUrgent: return String(localized: "live_activity_status_assignment_short")
    }
}

@ViewBuilder
private func countdownLabel(_ snapshot: LiveActivitySnapshot) -> some View {
    if let target = snapshot.countdownTarget, target > AppClock.now() {
        Text(timerInterval: Date()...AppClock.realTime(forApp: target), countsDown: true)
    } else {
        Text(terminalLabel(for: snapshot.scenario))
    }
}

private func terminalLabel(for scenario: LiveActivityScenarioKind) -> String {
    switch scenario {
    case .inClass:
        return String(localized: "live_activity_countdown_done_in_class")
    case .classPreparing:
        return String(localized: "live_activity_countdown_done_class_preparing")
    case .assignmentUrgent:
        return String(localized: "live_activity_countdown_done_assignment_urgent")
    }
}

private func hexColor(_ hex: Int) -> Color {
    let masked = UInt32(bitPattern: Int32(truncatingIfNeeded: hex)) & 0xFFFFFF
    let r = Double((masked >> 16) & 0xFF) / 255.0
    let g = Double((masked >> 8) & 0xFF) / 255.0
    let b = Double(masked & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}
