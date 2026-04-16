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
                    Image(systemName: iconName(for: snapshot.scenario))
                        .foregroundStyle(hexColor(snapshot.accentHex))
                }
            } compactTrailing: {
                countdownLabel(snapshot)
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(hexColor(snapshot.accentHex))
                    .frame(width: 60, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: status (leading, intrinsic width) + remaining countdown (trailing, intrinsic width)
            // Canonical pattern: Spacer 吃掉中間所有伸縮，兩側用 intrinsic size 自然貼齊邊界。
            // 注意：不可對右側 timer 或其容器使用 .fixedSize()，會破壞 Text(timerInterval:) 的
            // widget reservation 機制。
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

            // Row 2: title
            Text(snapshot.title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Row 3: progress bar (only when provided)
            if let progress = snapshot.progress {
                ProgressView(value: max(0, min(1, progress)))
                    .tint(hexColor(snapshot.accentHex))
                    .scaleEffect(x: 1, y: 1.2, anchor: .center)
                    .padding(.vertical, 6)
            }

            // Row 4: metadata — 地點 | Spacer | 時間 | Spacer | 老師
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    if let loc = snapshot.locationText, !loc.isEmpty {
                        Image(systemName: "mappin.and.ellipse")
                        Text(loc)
                    }
                }

                Spacer(minLength: 8)

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
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Dynamic Island expanded bottom (mirrors LockScreen rows 2-4)

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

            if let progress = snapshot.progress {
                ProgressView(value: max(0, min(1, progress)))
                    .tint(hexColor(snapshot.accentHex))
                    .scaleEffect(x: 1, y: 1.2, anchor: .center)
                    .padding(.vertical, 6)
            }

            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    if let loc = snapshot.locationText, !loc.isEmpty {
                        Image(systemName: "mappin.and.ellipse")
                        Text(loc)
                    }
                }

                Spacer(minLength: 8)

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
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
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

private func statusLabel(for scenario: LiveActivityScenarioKind) -> String {
    switch scenario {
    case .inClass: return "上課"
    case .classPreparing: return "即將上課"
    case .assignmentUrgent: return "作業"
    }
}

@ViewBuilder
private func countdownLabel(_ snapshot: LiveActivitySnapshot) -> some View {
    if let target = snapshot.countdownTarget, target > Date() {
        Text(timerInterval: Date()...target, countsDown: true)
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
