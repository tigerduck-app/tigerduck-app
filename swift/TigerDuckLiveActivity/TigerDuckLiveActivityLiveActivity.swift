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
            AutoProgressBar(snapshot: snapshot)

            // Row 4: metadata — layout depends on scenario
            MetadataRowView(snapshot: snapshot)
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

            AutoProgressBar(snapshot: snapshot)

            MetadataRowView(snapshot: snapshot)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

// MARK: - Progress bar (system-driven auto-interpolation)

/// OS-driven progress bar.
///
/// 底層邏輯：Live Activity 的 View 是快照型——`ProgressView(value:)` 只會在
/// 每次 push `Activity.update(...)` 時重繪。若僅靠 push 更新，既耗電又會被
/// 系統節流，使用者會看到「進度條卡住不動」。
///
/// 正確作法：用 `ProgressView(timerInterval:countsDown:)`——告訴系統這是
/// 一個時間區間，OS 在 widget extension 內部自動補間、零 CPU、零 push。
/// 這跟 `Text(timerInterval:)` 自動倒數文字是同一套機制。
private struct AutoProgressBar: View {
    let snapshot: LiveActivitySnapshot

    var body: some View {
        if let start = snapshot.progressStart,
           let target = snapshot.countdownTarget,
           start < target {
            // `ProgressView(timerInterval:)` interpolates against the real
            // wall clock, but the snapshot dates are in app-clock time
            // (possibly fake). Translate the endpoints once so the bar
            // animates over the matching real-time span.
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

// MARK: - Metadata row (shared by lock screen + dynamic island)

/// Scenario-aware bottom metadata row.
///
/// - inClass / classPreparing: 地點 | 時間 | 老師
/// - assignmentUrgent:         課程名稱(課本) |    | 指導老師
///   `subtitle` 對作業場景存放課程名稱；instructor 目前 resolver 恆為 nil，
///   故右側通常為空白（符合需求允許右側空白的備案）。
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

// MARK: - File-scope helpers (shared by lock screen + dynamic island)

/// The mark in the island's two small slots.
///
/// In class this is the app icon rather than a glyph: those slots are where
/// the system asks "which app is this?", and the tiger answers it in a way a
/// borrowed SF Symbol never did — a mortarboard reads as *some* school app.
/// The other two scenarios keep their glyph, which is carrying real
/// information the countdown alone doesn't (a class about to start vs. an
/// assignment about to be due).
///
/// Rendered at a fixed 20pt. The artwork is full-colour and detailed, so it
/// is not tinted with the accent the way a symbol is, and it must be sized
/// explicitly — an asset-catalog image in a widget otherwise lays out at its
/// natural size and blows the slot open.
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
    // Compare in app-clock space (fake time aware), but hand SwiftUI a
    // real-time range — `Text(timerInterval:)` ticks against the system
    // clock and would otherwise show ~a day off when fake time is set.
    if let target = snapshot.countdownTarget, target > AppClock.now() {
        Text(timerInterval: Date()...AppClock.realTime(forApp: target), countsDown: true)
    } else {
        Text(terminalLabel(for: snapshot.scenario))
    }
}

/// What the countdown slot reads once its target has passed.
///
/// Reaching this branch means nothing has ended the activity yet, and that
/// is a state the design has to survive rather than treat as impossible.
/// An end push is the only remote removal path — ActivityKit has no
/// expire-at-date API, and `staleDate` marks an activity stale without
/// dismissing it (see `LiveActivityCoordinator`) — while the local end
/// timer and the foreground prune both need the app to be running. So a
/// user lands here whenever the server is down, the phone is offline past
/// the push TTL, the push is dropped, or the app was force-quit.
///
/// `"—"` made every one of those read as a broken app. Naming the terminal
/// state costs nothing and makes the worst case look deliberate: the class
/// is over, and the island is saying so while it waits to be cleared.
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

/// Local helper (named `hexColor` not `accentColor` to avoid clashing with
/// the deprecated `View.accentColor(_:)` modifier during overload resolution).
private func hexColor(_ hex: Int) -> Color {
    // Clamp to a 24-bit RGB range so a corrupted snapshot (negative Int from
    // a buggy decoder, or a future >0xFFFFFF accent) can't drift channels.
    let masked = UInt32(bitPattern: Int32(truncatingIfNeeded: hex)) & 0xFFFFFF
    let r = Double((masked >> 16) & 0xFF) / 255.0
    let g = Double((masked >> 8) & 0xFF) / 255.0
    let b = Double(masked & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}
