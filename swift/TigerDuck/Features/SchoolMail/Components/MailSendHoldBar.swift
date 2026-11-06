#if os(iOS)
import Accessibility
import SwiftUI

struct MailSendHoldBar: View {
    let hold: MailSendHold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let held = hold.held {
                MailSendHoldCapsule(held: held) { hold.undo() }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smoothSpring, value: hold.held?.until)
    }
}

struct MailListBottomBar: View {
    let hold: MailSendHold
    let showsCompose: Bool
    let accentColor: Color
    let onCompose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            MailSendHoldBar(hold: hold)
            if showsCompose {
                MailComposeButton(accentColor: accentColor, action: onCompose)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: showsCompose)
    }
}

private struct MailSendHoldCapsule: View {
    let held: MailSendHold.Held
    let undo: () -> Void
    private static let ringSize: CGFloat = 30

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                status
                undoButton
            }
            VStack(alignment: .trailing, spacing: 0) {
                status.frame(maxWidth: .infinity, alignment: .leading)
                undoButton
            }
        }
        .font(.subheadline)
        .padding(.leading, TigerDuckTheme.Spacing.md)
        .padding(.trailing, TigerDuckTheme.Spacing.xs)
        .padding(.vertical, TigerDuckTheme.Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .glassCard(cornerRadius: TigerDuckTheme.CornerRadius.xl)
        .accessibilityElement(children: .contain)
        .onAppear(perform: announce)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.bottom, TigerDuckTheme.Spacing.sm)
    }

    private var status: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            TimelineView(.animation) { context in
                ProgressRing(fraction: held.remaining(at: context.date), lineWidth: 3)
            }
            .overlay {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: Self.ringSize, height: Self.ringSize)
            .accessibilityHidden(true)
            Text(String(localized: "school_mail_sending_hold"))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var undoButton: some View {
        Button(String(localized: "school_mail_undo_send"), action: undo)
            .fontWeight(.semibold)
            .padding(.horizontal, TigerDuckTheme.Spacing.md)
            .frame(minHeight: 44)
            .contentShape(.rect)
    }

    // A high priority keeps VoiceOver from cutting the announcement for the focus change the
    // closing composer brings.
    private func announce() {
        var text = AttributedString(String(localized: "school_mail_sending_hold"))
        text.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(text).post()
    }
}

extension View {
    func reopensHeldMail(_ hold: MailSendHold, isComposing: Bool, refresh: (@MainActor () async -> Void)? = nil) -> some View {
        modifier(MailHeldMailHost(hold: hold, isComposing: isComposing, refresh: refresh))
    }
}

private struct MailHeldMailHost: ViewModifier {
    let hold: MailSendHold
    let isComposing: Bool
    let refresh: (@MainActor () async -> Void)?
    @State private var isOnScreen = false
    @State private var reopened: MailComposeViewModel?

    func body(content: Content) -> some View {
        content
            .onAppear {
                isOnScreen = true
                take()
            }
            .onDisappear { isOnScreen = false }
            .onChange(of: hold.reopened == nil || isComposing) { take() }
            .onChange(of: hold.deliveries) { refreshList() }
            .sheet(item: $reopened, onDismiss: {
                take()
                refreshList()
            }) { model in
                MailComposeView(model: model, hold: hold)
            }
    }

    private func take() {
        guard isOnScreen, !isComposing, reopened == nil else { return }
        reopened = hold.takeReopened()
    }

    private func refreshList() {
        guard let refresh else { return }
        Task { await refresh() }
    }
}
#endif
