#if os(iOS)
import SwiftUI
import UIKit

enum FirstTriggerPromptKey: String {
    case flipToLibrary
}

struct FirstTriggerPromptContent {
    let title: String
    let message: String
    let animation: FirstTriggerAnimation
    let acceptLabel: String
    let declineLabel: String
    let onAccept: () -> Void
    let onDecline: () -> Void
}

enum FirstTriggerAnimation {
    case phoneFlip
}

@Observable
final class FirstTriggerPromptCenter {
    static let shared = FirstTriggerPromptCenter()

    struct Pending: Identifiable {
        let id = UUID()
        let key: FirstTriggerPromptKey
        let content: FirstTriggerPromptContent
    }

    var pending: Pending?

    private init() {}

    func hasSeen(_ key: FirstTriggerPromptKey) -> Bool {
        UserDefaults.standard.bool(forKey: Self.storageKey(key))
    }

    func requestIfFirstTime(
        _ key: FirstTriggerPromptKey,
        build: () -> FirstTriggerPromptContent
    ) {
        guard pending == nil, !hasSeen(key) else { return }
        pending = Pending(key: key, content: build())
    }

    func finish(accept: Bool) {
        guard let p = pending else { return }
        markSeen(p.key)
        pending = nil
        if accept {
            p.content.onAccept()
        } else {
            p.content.onDecline()
        }
    }

    func markSeen(_ key: FirstTriggerPromptKey) {
        UserDefaults.standard.set(true, forKey: Self.storageKey(key))
    }

    func reset(_ key: FirstTriggerPromptKey) {
        UserDefaults.standard.removeObject(forKey: Self.storageKey(key))
    }

    private static func storageKey(_ key: FirstTriggerPromptKey) -> String {
        "firstTriggerPromptSeen.\(key.rawValue)"
    }
}

private struct FirstTriggerPromptSheet: View {
    let promptKey: FirstTriggerPromptKey
    let content: FirstTriggerPromptContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            FirstTriggerAnimationView(animation: content.animation)
                .frame(height: 140)

            Text(content.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(content.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button {
                    FirstTriggerPromptCenter.shared.finish(accept: true)
                } label: {
                    Text(content.acceptLabel)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    FirstTriggerPromptCenter.shared.finish(accept: false)
                } label: {
                    Text(content.declineLabel)
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
    }
}

private struct FirstTriggerAnimationView: View {
    let animation: FirstTriggerAnimation
    @State private var flipped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var deviceSymbol: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad.gen2" : "iphone.gen3"
    }

    var body: some View {
        switch animation {
        case .phoneFlip:
            Image(systemName: deviceSymbol)
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(.tint)
                .rotation3DEffect(
                    .degrees(flipped ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.4
                )
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(
                        .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                    ) {
                        flipped = true
                    }
                }
                .accessibilityLabel(Text(String(localized: "first_trigger_phone_flip_accessibility")))
        }
    }
}

private struct FirstTriggerPromptHost: ViewModifier {
    @State private var center = FirstTriggerPromptCenter.shared

    func body(content: Content) -> some View {
        @Bindable var center = center
        return content.sheet(
            item: $center.pending,
            onDismiss: {
                if let stranded = center.pending,
                   !center.hasSeen(stranded.key) {
                    center.pending = nil
                }
            }
        ) { pending in
            FirstTriggerPromptSheet(promptKey: pending.key, content: pending.content)
                .presentationDetents([.fraction(0.7)])
                .interactiveDismissDisabled()
        }
    }
}

extension View {
    func firstTriggerPromptHost() -> some View {
        modifier(FirstTriggerPromptHost())
    }
}
#endif
