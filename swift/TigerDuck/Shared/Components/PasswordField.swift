import SwiftUI
import UIKit

struct PasswordField<Field: Hashable>: View {
    let placeholder: String
    @Binding var text: String
    var focusBinding: FocusState<Field?>.Binding
    let focusValue: Field
    var returnKeyType: UIReturnKeyType = .go
    var onSubmit: () -> Void = {}

    @State private var isVisible = false
    @State private var isScreenCaptured = false
    @State private var showsCaptureExplanation = false
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
                    showsCaptureExplanation = true
                } else {
                    handleEyeTap()
                }
            } label: {
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
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .frame(width: 260)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .background(
            CapturedScreenReader { captured in
                let wasCaptured = isScreenCaptured
                isScreenCaptured = captured
                if captured {
                    forceMask()
                } else if wasCaptured {
                    showsCaptureExplanation = false
                }
            }
        )
        .onChange(of: showsCaptureExplanation) { _, isShown in
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

    private func handleEyeTap() {
        isVisible.toggle()
    }

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

        if isFocused {
            DispatchQueue.main.async { [weak field] in
                guard let field, !field.isFirstResponder else { return }
                _ = field.becomeFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        let intrinsicHeight = uiView.intrinsicContentSize.height
        let height = intrinsicHeight > 0 ? intrinsicHeight : 30
        let width = proposal.width ?? UIView.noIntrinsicMetric
        return CGSize(width: width, height: height)
    }

    private func applySecureTextEntry(_ isSecure: Bool, on field: UITextField) {
        let savedText = field.text
        let savedOffsets: (start: Int, end: Int)? = {
            guard let range = field.selectedTextRange else { return nil }
            let start = field.offset(from: field.beginningOfDocument, to: range.start)
            let end = field.offset(from: field.beginningOfDocument, to: range.end)
            return (start, end)
        }()

        field.isSecureTextEntry = isSecure

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
            DispatchQueue.main.async { [weak self, weak textField] in
                guard let self, let textField, textField.isFirstResponder else { return }
                if !self.parent.isFocused { self.parent.isFocused = true }
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
