import SwiftUI

/// Asks whether to continue to a host whose certificate chain no longer matches its pins, with
/// the served chain one push away.
struct TLSPinPromptSheet: View {
    let prompt: TLSPinMismatch
    let onCancel: () -> Void
    let onContinue: () -> Void

    @State private var showsDetails = false
    @State private var showsCertificates = false
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title) private var badgeSize: CGFloat = 60
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @State private var detent: PresentationDetent = .medium
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    header
                    hostLines
                    details
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.xl)
                .padding(.top, TigerDuckTheme.Spacing.xxl)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { buttons }
            .navigationDestination(isPresented: $showsCertificates) {
                // A pushed list ignores an inset set on the stack, and its last rows would sit
                // under the buttons, so each page sets its own.
                TLSCertificateList(prompt: prompt) { showsCertificates = false }
                    .safeAreaInset(edge: .bottom) { buttons }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .background { escapeCloses }
        #if os(iOS)
        .presentationDetents([.medium, .large], selection: $detent)
        .onAppear { if dynamicTypeSize.isAccessibilitySize { detent = .large } }
        .onChange(of: showsDetails || showsCertificates) { _, opened in
            if opened { detent = .large }
        }
        #else
        .frame(minWidth: 420, idealWidth: 460, minHeight: 480, idealHeight: 560)
        #endif
    }

    private var header: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.title)
                .foregroundStyle(TigerDuckTheme.Tint.orange)
                .frame(width: badgeSize, height: badgeSize)
                .background(TigerDuckTheme.Tint.orange.opacity(0.14), in: .circle)
                .accessibilityHidden(true)
            Text(String(localized: "tls_pin_mismatch_title"))
                .font(TigerDuckTheme.Typography.title)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(String(localized: "tls_pin_mismatch_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var hostLines: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            Text(prompt.host)
                .font(.subheadline.monospaced())
                .multilineTextAlignment(.center)
                .padding(.horizontal, TigerDuckTheme.Spacing.md)
                .padding(.vertical, TigerDuckTheme.Spacing.sm)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md))
                .textSelection(.enabled)
            if let issuer = prompt.issuerOrganization {
                Text(String(format: String(localized: "tls_pin_mismatch_issuer"), issuer))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// A disclosure in a capsule like Cancel and Continue, so VoiceOver reads it expanded or
    /// collapsed.
    private var details: some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            Text(String(
                format: String(localized: "tls_pin_mismatch_details"),
                prompt.host, prompt.domains.formatted(.list(type: .and, width: .narrow))
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                showsCertificates = true
            } label: {
                capsuleLabel(String(localized: "tls_pin_mismatch_view_certificate"), systemImage: "chevron.forward")
            }
            .promptButtonStyle(prominent: false)
        } label: {
            Text(String(localized: "tls_pin_mismatch_show_details"))
        }
        .disclosureGroupStyle(CapsuleDisclosure())
        .buttonBorderShape(.capsule)
    }

    private func capsuleLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.xs) {
            Text(title)
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .accessibilityHidden(true)
        }
    }

    private var buttons: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    continueButton
                    cancelButton
                }
            } else {
                HStack(spacing: TigerDuckTheme.Spacing.md) {
                    cancelButton
                    continueButton
                }
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, TigerDuckTheme.Spacing.xl)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .background(.bar)
    }

    private var cancelButton: some View {
        Button(action: onCancel) { buttonLabel(String(localized: "action_cancel")) }
            .promptButtonStyle(prominent: false)
    }

    /// A sheet takes Escape only through a cancel button. This one closes the sheet unanswered, as
    /// a swipe does, where Cancel would answer.
    private var escapeCloses: some View {
        Button("") { dismiss() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var continueButton: some View {
        Button(action: onContinue) { buttonLabel(String(localized: "action_continue")) }
            .promptButtonStyle(prominent: true)
    }

    private func buttonLabel(_ title: String) -> some View {
        Text(title)
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
    }
}

private struct TLSCertificateList: View {
    let prompt: TLSPinMismatch
    let onBack: () -> Void

    var body: some View {
        Form {
            ForEach(Array(prompt.certificates.enumerated()), id: \.offset) { index, certificate in
                Section {
                    LabeledContent(String(localized: "tls_certificate_name"), value: certificate.name)
                    LabeledContent(String(localized: "tls_certificate_issuer"), value: certificate.issuer)
                    LabeledContent(String(localized: "tls_certificate_validity"), value: Self.validity(certificate))
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                        Text(String(localized: "tls_certificate_fingerprint"))
                        Text(certificate.sha256Fingerprint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text(heading(index)).textCase(nil)
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        // A Mac sheet has no title bar for the navigation title or a back button.
        .safeAreaInset(edge: .top) {
            Text(String(localized: "tls_certificate_list_title"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel(String(localized: "action_back"))
                }
                .padding([.top, .horizontal], TigerDuckTheme.Spacing.lg)
        }
        #endif
        .navigationTitle(String(localized: "tls_certificate_list_title"))
        .inlineNavigationTitle()
    }

    private func heading(_ index: Int) -> String {
        if index == 0 { return prompt.host }
        return index == prompt.certificates.count - 1
            ? String(localized: "tls_certificate_root")
            : String(localized: "tls_certificate_intermediate")
    }

    static func validity(_ certificate: TLSCertificateSummary) -> String {
        [certificate.notBefore, certificate.notAfter].compactMap { $0?.fullDateString }.joined(separator: " – ")
    }
}

private struct CapsuleDisclosure: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            Button {
                withAnimation { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: TigerDuckTheme.Spacing.xs) {
                    configuration.label
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
            }
            .promptButtonStyle(prominent: false)
            if configuration.isExpanded { configuration.content }
        }
    }
}

private extension View {
    @ViewBuilder
    func promptButtonStyle(prominent: Bool) -> some View {
        if #available(iOS 26, macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}
