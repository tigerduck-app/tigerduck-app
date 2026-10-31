import Defaults
import SwiftUI

extension View {
    func moodleRefreshFailureNote<Value>(
        _ feed: MoodleFeed<Value>,
        hasContent: Bool,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> some View {
        modifier(MoodleRefreshFailureNote(
            failureCount: feed.failureCount, failure: feed.failure, hasContent: hasContent, sleep: sleep
        ))
    }
}

@MainActor
@Observable
final class MoodleRefreshFailureNoteModel {
    static let duration: Duration = .seconds(3)

    private(set) var note: MoodleRefreshFailureNote.Note?
    @ObservationIgnored private var isShown = false
    @ObservationIgnored private var notesShown = 0
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void

    init(sleep: @escaping @Sendable (Duration) async -> Void) {
        self.sleep = sleep
    }

    func appeared() { isShown = true }

    func disappeared() {
        isShown = false
        note = nil
    }

    func failed(_ failure: (any Error)?, hasContent: Bool) -> MoodleRefreshFailureNote.Note? {
        guard let next = MoodleRefreshFailureNote.note(for: failure, hasContent: hasContent, isShown: isShown) else {
            return nil
        }
        notesShown += 1
        let shown = notesShown
        note = next
        let sleep = sleep
        Task { [weak self] in
            await sleep(Self.duration)
            self?.hide(ifStill: shown)
        }
        return next
    }

    func hide(ifStill shown: Int) {
        guard notesShown == shown else { return }
        note = nil
    }

    func close() { note = nil }
}

struct MoodleRefreshFailureNote: ViewModifier {
    struct Note: Equatable {
        let text: String
        let symbol: String
    }

    let failureCount: Int
    let failure: (any Error)?
    let hasContent: Bool
    @State private var model: MoodleRefreshFailureNoteModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(failureCount: Int, failure: (any Error)?, hasContent: Bool, sleep: @escaping @Sendable (Duration) async -> Void) {
        self.failureCount = failureCount
        self.failure = failure
        self.hasContent = hasContent
        _model = State(initialValue: MoodleRefreshFailureNoteModel(sleep: sleep))
    }

    static func note(for failure: (any Error)?, hasContent: Bool, isShown: Bool) -> Note? {
        guard let failure, hasContent, isShown else { return nil }
        if MoodleFirstLoadView.isNetworkError(failure) {
            return Note(text: String(localized: "error_network_unavailable"), symbol: "wifi.slash")
        }
        if MoodleFailure.isSiteMaintenance(failure) {
            return Note(text: String(localized: "error_moodle_site_maintenance"), symbol: "exclamationmark.triangle")
        }
        return Note(text: String(localized: "course_moodle_refresh_failed"), symbol: "exclamationmark.triangle")
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ZStack {
                    if let note = model.note {
                        noteButton(note)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy, value: model.note)
            }
            .onAppear { model.appeared() }
            .onDisappear { model.disappeared() }
            .onChange(of: failureCount) { _, _ in
                guard let note = model.failed(failure, hasContent: hasContent) else { return }
                AccessibilityNotification.Announcement(note.text).post()
            }
    }

    private func noteButton(_ note: Note) -> some View {
        Button { model.close() } label: {
            Label {
                Text(note.text)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.leading)
            } icon: {
                Image(systemName: note.symbol).foregroundStyle(Color.schoolOrange)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.top, TigerDuckTheme.Spacing.sm)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}
