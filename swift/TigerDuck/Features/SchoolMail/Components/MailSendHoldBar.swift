#if os(iOS)
import SwiftUI
import UIKit

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
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: showsCompose)
    }
}

private struct MailSendHoldCapsule: View {
    let held: MailSendHold.Held
    let undo: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 30
    @ScaledMetric(relativeTo: .subheadline) private var ringWidth: CGFloat = 3

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                ring
                label
                undoButton
            }
            VStack(alignment: .leading, spacing: 0) {
                label
                HStack {
                    ring
                    Spacer(minLength: 0)
                    undoButton
                }
            }
        }
        .font(.subheadline)
        .padding(.leading, TigerDuckTheme.Spacing.md)
        .padding(.trailing, TigerDuckTheme.Spacing.xs)
        .padding(.vertical, TigerDuckTheme.Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .glassCard(cornerRadius: TigerDuckTheme.CornerRadius.xl)
        .accessibilityElement(children: .contain)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.bottom, TigerDuckTheme.Spacing.sm)
    }

    private var ring: some View {
        TimelineView(.animation) { context in
            ProgressRing(fraction: held.remaining(at: context.date), lineWidth: ringWidth)
        }
        .overlay {
            Image(systemName: "paperplane.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
        }
        .frame(width: ringSize, height: ringSize)
        .accessibilityHidden(true)
    }

    private var label: some View {
        Text(String(localized: "school_mail_sending_hold"))
            .foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var undoButton: some View {
        Button(String(localized: "school_mail_undo_send"), action: undo)
            .fontWeight(.semibold)
            .padding(.horizontal, TigerDuckTheme.Spacing.md)
            .frame(minHeight: 44)
            .contentShape(.rect)
    }
}

enum MailReopenTurn: Equatable {
    case now
    case afterActiveWindows
    case never

    init(_ state: UIScene.ActivationState?) {
        switch state {
        case .foregroundActive: self = .now
        case .foregroundInactive, nil: self = .afterActiveWindows
        default: self = .never
        }
    }
}

extension View {
    func heldMailHost(_ hold: MailSendHold = .shared) -> some View {
        modifier(MailHeldMailHost(hold: hold))
    }
}

private struct MailHeldMailHost: ViewModifier {
    private struct Wait: Equatable {
        let next: ObjectIdentifier?
        let activations: Int
    }

    private static let inactiveWindowDelay: Duration = .milliseconds(500)
    private static let presentationPoll: Duration = .milliseconds(100)

    let hold: MailSendHold
    @Environment(AppEnvironment.self) private var app: AppEnvironment?
    @State private var shown: MailComposeViewModel?
    @State private var hostWindow = HostWindow()
    @State private var activations = 0

    private var turn: MailReopenTurn { MailReopenTurn(hostWindow.window?.windowScene?.activationState) }

    func body(content: Content) -> some View {
        content
            .task(id: Wait(next: shown == nil ? hold.reopened.first?.id : nil, activations: activations)) { await showNext() }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in activations += 1 }
            .readsHostWindow(into: hostWindow)
    }

    private func showNext() async {
        guard shown == nil, let next = hold.reopened.first else { return }
        switch turn {
        case .now: break
        case .afterActiveWindows: try? await AppClock.sleep(until: ContinuousClock.now + Self.inactiveWindowDelay)
        case .never: return
        }
        guard turn != .never, let top = await presenter(),
              !Task.isCancelled, shown == nil, hold.reopened.first === next
        else { return }
        // SwiftUI presents a sheet only from a view with nothing presented, and a sheet such as a
        // course's may stay open under the composer.
        let composer = UIHostingController(rootView: MailReopenedComposer(model: next, hold: hold, app: app) {
            hold.composerClosed(next)
            shown = nil
        })
        top.present(composer, animated: true)
        guard composer.presentingViewController != nil else { return }
        shown = hold.takeReopened()
    }

    /// UIKit presents nothing during a transition, and closes a composer over an alert along with the alert.
    private func presenter() async -> UIViewController? {
        while !Task.isCancelled, let top = hostWindow.topmostPresented {
            guard top is UIAlertController || top.transitionCoordinator != nil else { return top }
            try? await AppClock.sleep(until: ContinuousClock.now + Self.presentationPoll)
        }
        return nil
    }
}

/// A view UIKit presents does not inherit the root's environment.
private struct MailReopenedComposer: View {
    let model: MailComposeViewModel
    let hold: MailSendHold
    let app: AppEnvironment?
    let closed: () -> Void

    var body: some View {
        MailComposeView(viewModel: model, hold: hold)
            .tint(app?.preferences.accentTint)
            .appAppearance()
            .environment(app)
            .onDisappear(perform: closed)
    }
}
#endif
