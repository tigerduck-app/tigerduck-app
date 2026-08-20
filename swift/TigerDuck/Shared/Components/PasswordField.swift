import SwiftUI
import UIKit

/// Password input with a trailing eye toggle.
///
/// Backed by a single `UITextField` via `UIViewRepresentable` so toggling
/// secure entry does not tear down the first responder. The field tracks
/// `isVisible` directly: masked uses `isSecureTextEntry = true` (keyboard
/// in passcode mode → no key-preview popovers, no QuickType bar, excluded
/// from screen recording); revealed uses normal text entry (visible
/// cleartext, native cursor positioning, selection, copy / paste, normal
/// keyboard).
///
/// The reveal threat model: if the user has tapped the eye, the password
/// is already on screen. The keyboard becoming a normal (visible-in-
/// recording) keyboard at that point is consistent with the exposure the
/// user just opted into — it isn't a new leak. To minimize the surface,
/// the eye tap dismisses the keyboard first; the user can tap the field
/// again to bring it up in whichever mode matches the current state.
///
/// Two extra defense-in-depth layers on top of the always-on
/// `.screenCaptureProtected(true)` (which keeps the field's pixels out of
/// screenshots/recording even when revealed):
///
/// - **Lock reveal during active capture.** While `UIScreen.main.isCaptured`
///   is true (screen recording, mirroring, AirPlay), the eye button is
///   disabled and any current reveal is force-masked. The user can't
///   accidentally expose the password to whoever is on the other end of
///   the stream.
/// - **Auto-mask on screenshot.** iOS doesn't expose a pre-screenshot
///   hook (only `userDidTakeScreenshotNotification`, which fires *after*
///   the volume+power press). The secure canvas already blanks the
///   password area in the captured image, but we additionally flip back
///   to masked on the notification so any subsequent glance / second
///   screenshot also sees the dots.
struct PasswordField<Field: Hashable>: View {
    let placeholder: String
    @Binding var text: String
    var focusBinding: FocusState<Field?>.Binding
    let focusValue: Field
    var returnKeyType: UIReturnKeyType = .go
    var onSubmit: () -> Void = {}

    @State private var isVisible = false
    /// Drives the eye gating. Populated by `CapturedScreenReader` below,
    /// which reads `isCaptured` from the *hosting window's* `UIScreen` —
    /// `UIScreen.main` is deprecated on iOS 16+ and returns the wrong
    /// screen in multi-scene / Stage Manager / Sidecar configurations.
    @State private var isScreenCaptured = false
    @State private var showsCaptureExplanation = false
    /// Monotonically incremented each time the explanation popover opens;
    /// the deferred auto-dismiss closure ignores its work if a newer open
    /// has happened in the meantime, so rapid re-taps don't get their
    /// fresh popover dismissed by a stale timer.
    @State private var captureExplanationGen = 0

    var body: some View {
        HStack(spacing: 4) {
            _PasswordTextField(
                placeholder: placeholder,
                text: $text,
                isSecure: !isVisible,
                isFocused: Binding(
                    get: { focusBinding.wrappedValue == focusValue },
                    set: { newValue in
                        if newValue {
                            focusBinding.wrappedValue = focusValue
                        } else if focusBinding.wrappedValue == focusValue {
                            focusBinding.wrappedValue = nil
                        }
                    }
                ),
                returnKeyType: returnKeyType,
                onSubmit: onSubmit
            )
            .screenCaptureProtected(true)

            Button {
                if isScreenCaptured {
                    // Tapping the eye while capture is active surfaces an
                    // inline popover explaining why reveal is unavailable
                    // rather than just being inert. See the `.popover`
                    // modifier below.
                    showsCaptureExplanation = true
                } else {
                    handleEyeTap()
                }
            } label: {
                // Open eye = password is currently visible; eye.slash =
                // currently hidden. (Mirror-the-state reading, not
                // tap-to-action.)
                Image(systemName: isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(isScreenCaptured ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible
                ? String(localized: "password_hide")
                : String(localized: "password_show"))
            .popover(isPresented: $showsCaptureExplanation, arrowEdge: .top) {
                Text(String(localized: "password_eye_unavailable_during_capture"))
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    // `.fixedSize(vertical: true)` lets the text grow
                    // downward to fit; the surrounding `.frame(width:)`
                    // gives it a stable horizontal budget. Without
                    // fixedSize, the popover assigns a 1-line slot and
                    // truncates with an ellipsis.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .frame(width: 260)
                    // Forces a real popover with arrow on compact-width
                    // (iPhone) instead of SwiftUI's default sheet
                    // adaptation, so the arrow can actually point at the
                    // eye glyph.
                    .presentationCompactAdaptation(.popover)
            }
        }
        .background(
            // Reads the hosting window's `UIScreen.isCaptured` and
            // observes change notifications scoped to that specific
            // screen (not all screens) — handles multi-scene / external
            // display correctly, and notifications fire only for the
            // screen this field is actually showing on.
            CapturedScreenReader { captured in
                let wasCaptured = isScreenCaptured
                isScreenCaptured = captured
                if captured {
                    forceMask()
                } else if wasCaptured {
                    // Capture ended — the "unavailable" explanation is no
                    // longer accurate, so close it if it was open.
                    showsCaptureExplanation = false
                }
            }
        )
        .onChange(of: showsCaptureExplanation) { _, isShown in
            // Auto-dismiss after ~4s; users can also dismiss by tapping
            // outside (default popover behavior). The gen counter
            // prevents a stale timer from closing a newer popover that
            // was opened after a quick re-tap.
            guard isShown else { return }
            captureExplanationGen &+= 1
            let gen = captureExplanationGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard gen == captureExplanationGen else { return }
                showsCaptureExplanation = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            forceMask()
        }
    }

    /// The eye is gated while a capture is in progress (tap routes to
    /// the explainer popover instead — see the button action above), so
    /// toggling can only happen when nothing is being recorded. That
    /// means the brief passcode↔normal keyboard-mode transition when
    /// `isSecureTextEntry` flips on a focused field is safe to render
    /// in place. Keeping the keyboard up means the user doesn't have
    /// to re-tap the field to keep typing after they've checked their
    /// password.
    private func handleEyeTap() {
        isVisible.toggle()
    }

    /// Force-mask without changing focus state if there's nothing to
    /// mask. Called from the capture / screenshot observers.
    ///
    /// IMPORTANT: only touches focus when *this* field is the focused
    /// one. The same `@FocusState` is shared across the surrounding
    /// form's username + password fields (e.g. LibraryView /
    /// LoginSheet / OnboardingView all pass a single `$focusedField`
    /// binding); unconditionally clearing it would yank focus off the
    /// username field a user has just tabbed back to while the
    /// password reveal was incidentally still on.
    private func forceMask() {
        guard isVisible else { return }
        let owningFocus = focusBinding.wrappedValue == focusValue
        if owningFocus {
            UIApplication.dismissKeyboard()
            focusBinding.wrappedValue = nil
        }
        isVisible = false
    }
}

/// Reports the captured state of the `UIScreen` hosting this view, and
/// re-reports whenever that screen posts `capturedDidChangeNotification`.
///
/// Scoped by `object: screen` so a capture flip on an *external* screen
/// (e.g. an attached USB-C display) doesn't fire the handler for a view
/// living on the iPhone's internal screen. Replaces direct
/// `UIScreen.main.isCaptured` reads, which are deprecated on iOS 16+ and
/// undefined on multi-scene iPad / Stage Manager.
private struct CapturedScreenReader: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> CapturedScreenReaderView {
        let view = CapturedScreenReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: CapturedScreenReaderView, context: Context) {
        uiView.onChange = onChange
    }
}

private final class CapturedScreenReaderView: UIView {
    var onChange: ((Bool) -> Void)?
    private var observer: NSObjectProtocol?
    private weak var observedScreen: UIScreen?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        // The reader is a SwiftUI `.background`, but it carries zero
        // visual weight — let it shrink to zero rather than influencing
        // layout of the wrapped content.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this view is created programmatically")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Reattach the observer to whichever `UIScreen` now hosts us
        // (or detach entirely if the view left the hierarchy).
        let newScreen = window?.screen
        if newScreen === observedScreen { return }

        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        observedScreen = newScreen
        guard let newScreen else { return }

        onChange?(newScreen.isCaptured)
        observer = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: newScreen,
            queue: .main
        ) { [weak self, weak newScreen] _ in
            guard let newScreen else { return }
            // iOS posts the notification a tick before `isCaptured`
            // flips to its new value on `recording stopped`. Hop to
            // the next runloop turn so the read picks up the updated
            // value.
            DispatchQueue.main.async {
                self?.onChange?(newScreen.isCaptured)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private struct _PasswordTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    @Binding var isFocused: Bool
    let returnKeyType: UIReturnKeyType
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.isSecureTextEntry = isSecure
        field.keyboardType = .asciiCapable
        field.textContentType = .password
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = returnKeyType
        field.clearButtonMode = .never
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self

        if field.placeholder != placeholder { field.placeholder = placeholder }
        if field.returnKeyType != returnKeyType { field.returnKeyType = returnKeyType }
        if field.text != text { field.text = text }

        if field.isSecureTextEntry != isSecure {
            applySecureTextEntry(isSecure, on: field)
        }

        // Mirror @FocusState → UITextField for the BECOME direction only.
        //
        // We deliberately do not call `resignFirstResponder` from here. UIKit
        // already transfers first responder automatically when another control
        // is tapped or programmatically focused, and trying to resign in
        // response to a transient `focusedField == nil` (which SwiftUI emits
        // during a tap-driven focus migration from a sibling field) is what
        // produced the brief keyboard collapse-and-expand on field switches.
        if isFocused {
            DispatchQueue.main.async { [weak field] in
                guard let field, !field.isFirstResponder else { return }
                _ = field.becomeFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        // Without this, the wrapped `UITextField` reports `noIntrinsicMetric`
        // for width and SwiftUI's HStack will not necessarily hand it the
        // remaining horizontal space the way it does for a native `TextField`.
        // The field then collapses to ~zero width and taps never land on it.
        let intrinsicHeight = uiView.intrinsicContentSize.height
        let height = intrinsicHeight > 0 ? intrinsicHeight : 30
        let width = proposal.width ?? UIView.noIntrinsicMetric
        return CGSize(width: width, height: height)
    }

    /// Flip `isSecureTextEntry` on the live field without losing typed text
    /// or moving first responder.
    ///
    /// Apple's documented behaviour is that toggling `isSecureTextEntry`
    /// while text is being entered clears the field. We work around it by
    /// reassigning `text` (nil → saved value), which leaves the field in
    /// a stable internal state without dropping first responder, then we
    /// restore the caret/selection by character offset (the saved
    /// `UITextRange` becomes invalid the moment `text` is reassigned).
    private func applySecureTextEntry(_ isSecure: Bool, on field: UITextField) {
        let savedText = field.text
        let savedOffsets: (start: Int, end: Int)? = {
            guard let range = field.selectedTextRange else { return nil }
            let start = field.offset(from: field.beginningOfDocument, to: range.start)
            let end = field.offset(from: field.beginningOfDocument, to: range.end)
            return (start, end)
        }()

        field.isSecureTextEntry = isSecure

        // Only the editing-in-progress path needs the round-trip; if no one
        // is editing, the toggle alone is harmless.
        guard field.isFirstResponder else { return }

        field.text = nil
        field.text = savedText

        guard let savedOffsets,
              let start = field.position(from: field.beginningOfDocument, offset: savedOffsets.start),
              let end = field.position(from: field.beginningOfDocument, offset: savedOffsets.end),
              let restored = field.textRange(from: start, to: end)
        else { return }
        field.selectedTextRange = restored
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: _PasswordTextField

        init(parent: _PasswordTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ sender: UITextField) {
            let newValue = sender.text ?? ""
            if parent.text != newValue { parent.text = newValue }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            // Defer to the next runloop tick for two reasons:
            // 1) Avoid mutating SwiftUI state from inside the UIKit responder
            //    transition stack frame.
            // 2) Sequence our write AFTER SwiftUI's internal bridge for the
            //    previously focused field (which may queue a transient
            //    `focusedField = nil`). FIFO of `DispatchQueue.main.async`
            //    means our write, queued later, wins.
            DispatchQueue.main.async { [weak self, weak textField] in
                guard let self, let textField, textField.isFirstResponder else { return }
                if !self.parent.isFocused { self.parent.isFocused = true }
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // Intentionally do not write `focusedField = nil` here. When a
            // sibling field is taking over, its own SwiftUI focus bridge has
            // already installed the correct value; writing nil here would
            // race against it and clobber the new focus.
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
