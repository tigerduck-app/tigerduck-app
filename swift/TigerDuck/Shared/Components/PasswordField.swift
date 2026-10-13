import SwiftUI
import UIKit

/// Password input with an eye toggle.
///
/// One `UITextField` keeps the first responder across toggles. Masked, it uses the
/// passcode keyboard: no key previews, no QuickType bar, hidden from recordings.
/// Revealed, its normal keyboard leaks nothing new: the password is shown anyway.
/// `.screenCaptureProtected(true)` blanks the field in any capture. Reveal is also
/// locked and undone while the screen is captured (recording, mirroring, AirPlay),
/// and a screenshot re-masks it for later glances: iOS reports one only afterwards.
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
                    // During capture the eye opens the `.popover` below, which
                    // explains why reveal is unavailable, instead of doing nothing.
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
                    // Without `.fixedSize(vertical: true)` the popover gives the
                    // text one line and truncates it; with it the text grows
                    // downward within the width `.frame(width:)` sets.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .frame(width: 260)
                    // A real popover on compact width (iPhone) instead of the
                    // default sheet adaptation, so the arrow points at the eye.
                    .presentationCompactAdaptation(.popover)
            }
        }
        .background(
            // Reads `isCaptured` from the hosting window's screen and observes only
            // that screen's notifications, so multi-scene and external displays work
            // and a capture on another screen does not affect this field.
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
            // Auto-dismiss after ~4s, on top of the default tap-outside dismissal.
            // The gen counter keeps a stale timer from closing a popover reopened
            // by a quick re-tap.
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

    /// Masks a revealed password; when already masked it does nothing, focus
    /// included. Called from the capture and screenshot observers.
    ///
    /// Dismisses the keyboard and clears focus only when this field holds it.
    /// The form's username and password fields share one `@FocusState`
    /// (`LibraryView`, `LoginSheet` and `OnboardingView` pass a single
    /// `$focusedField`), so clearing it always would pull focus off a username
    /// field the user just moved back to while the reveal was still on.
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
            // When recording stops, iOS posts this a tick before `isCaptured`
            // flips, so the read waits for the next runloop turn.
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

        // Mirror @FocusState into the field only to become first responder. Resigning
        // here on the transient nil SwiftUI emits while focus moves between fields
        // collapses and reopens the keyboard, and UIKit moves first responder itself.
        if isFocused {
            DispatchQueue.main.async { [weak field] in
                guard let field, !field.isFirstResponder else { return }
                _ = field.becomeFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        // Without this the field reports `noIntrinsicMetric` width, the HStack may not
        // give it the remaining space as it would a native `TextField`, and it collapses
        // to about zero width where taps never land.
        let intrinsicHeight = uiView.intrinsicContentSize.height
        let height = intrinsicHeight > 0 ? intrinsicHeight : 30
        let width = proposal.width ?? UIView.noIntrinsicMetric
        return CGSize(width: width, height: height)
    }

    /// Flip `isSecureTextEntry` on the live field without losing typed text
    /// or moving first responder.
    ///
    /// Apple documents that toggling it during text entry clears the field.
    /// Reassigning `text` (nil, then the saved value) keeps the field stable
    /// without dropping first responder; the selection is then restored by
    /// character offset, since the saved `UITextRange` is invalid once `text`
    /// is reassigned.
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
            // Deferred so SwiftUI state is not mutated inside UIKit's responder change,
            // and so this write lands after the transient `focusedField = nil` SwiftUI
            // may queue for the previous field: the main queue runs in FIFO order.
            DispatchQueue.main.async { [weak self, weak textField] in
                guard let self, let textField, textField.isFirstResponder else { return }
                if !self.parent.isFocused { self.parent.isFocused = true }
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // No `focusedField = nil` here: when a sibling field takes over, its
            // focus bridge has already set the right value, and writing nil would
            // race it and clobber the new focus.
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
