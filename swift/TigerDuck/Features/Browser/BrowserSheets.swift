import SwiftUI
import WebKit

enum BrowserSheet: String, Identifiable {
    case address, certificate, more

    var id: String { rawValue }
}

/// The browser's sheets, sized to their content and closed by dragging down; the certificate
/// page opens from the address sheet, or alone from the address menu.
struct BrowserSheetView: View {
    let page: BrowserPage
    let sheet: BrowserSheet
    let showsNavigation: Bool
    let afterClosing: (@escaping () -> Void) -> Void

    @State private var showsCertificate: Bool
    @State private var height: CGFloat = 160

    init(page: BrowserPage, sheet: BrowserSheet, showsNavigation: Bool, afterClosing: @escaping (@escaping () -> Void) -> Void) {
        self.page = page
        self.sheet = sheet
        self.showsNavigation = showsNavigation
        self.afterClosing = afterClosing
        _showsCertificate = State(initialValue: sheet == .certificate)
    }

    var body: some View {
        Group {
            if sheet == .more {
                BrowserMenu(page: page, showsNavigation: showsNavigation, afterClosing: afterClosing)
                    .fittedHeight($height)
            } else {
                NavigationStack {
                    BrowserAddressView(page: page, showsCertificate: $showsCertificate)
                        .fittedHeight($height)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color(uiColor: .systemGroupedBackground))
                        // The content runs under the empty bar, which stays shown: a push that brings
                        // a hidden bar in lays it out too high until the push ends.
                        .ignoresSafeArea(.container, edges: .top)
                        .navigationDestination(isPresented: $showsCertificate) {
                            BrowserCertificateView(chain: BrowserCertificate.chain(of: page.connection == .secure ? page.serverTrust : nil))
                        }
                }
            }
        }
        .presentationDetents(showsCertificate ? [.large] : [.height(height)])
        .presentationDragIndicator(.visible)
        .centeredPlacement()
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }
}

private extension View {
    func fittedHeight(_ height: Binding<CGFloat>) -> some View {
        fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height.wrappedValue = $0 }
    }

    /// The iOS 27 SDK's automatic placement moves a small sheet toward the button that opened it.
    @ViewBuilder
    func centeredPlacement() -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27, *) { presentationPlacement(.center) } else { self }
        #else
        self
        #endif
    }
}

private struct BrowserAddressView: View {
    let page: BrowserPage
    @Binding var showsCertificate: Bool
    @State private var signedIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(page.address?.absoluteString ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, TigerDuckTheme.Spacing.xs)
            let connection = page.connection
            if connection != .unknown || signedIn {
                VStack(spacing: 0) {
                    if connection != .unknown {
                        connectionRow(connection)
                    }
                    if connection != .unknown, signedIn {
                        Divider().padding(.leading, 52)
                    }
                    if signedIn {
                        HStack(spacing: TigerDuckTheme.Spacing.md) {
                            Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.tint).frame(width: 24)
                            Text(String(localized: "browser_signed_in"))
                            Spacer(minLength: 0)
                        }
                        .padding(TigerDuckTheme.Spacing.lg)
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.xl)
        .padding(.bottom, TigerDuckTheme.Spacing.lg)
        .task {
            guard let address = page.address, BrowserRouting.isMoodleReturnPage(address) else { return }
            signedIn = BrowserRouting.hasMoodleSession(await page.store.httpCookieStore.allCookies())
        }
    }

    @ViewBuilder
    private func connectionRow(_ connection: BrowserPage.Connection) -> some View {
        if connection == .refused {
            // The web view still holds the last trusted page's certificate, so nothing links to it.
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red).frame(width: 24)
                Text(String(localized: "browser_certificate_invalid")).fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .padding(TigerDuckTheme.Spacing.lg)
        } else {
            Button { showsCertificate = true } label: {
                HStack(spacing: TigerDuckTheme.Spacing.md) {
                    Image(systemName: "lock.fill").foregroundStyle(.green).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "browser_connection_secure")).fontWeight(.semibold)
                        Text(String(localized: "browser_connection_secure_detail"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(String(localized: "browser_certificate")).font(.subheadline).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(TigerDuckTheme.Spacing.lg)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct BrowserCertificateView: View {
    let chain: [BrowserCertificate]
    @State private var selected = 0
    @State private var copied = false

    var body: some View {
        Form {
            if chain.indices.contains(selected) {
                details(of: chain[selected])
            } else {
                Text(String(localized: "browser_certificate_none")).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "browser_certificate_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if chain.indices.contains(selected) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "browser_certificate_copy"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = Self.summary(of: chain[selected])
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.4))
                            copied = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func details(of certificate: BrowserCertificate) -> some View {
        Section {
            Label(String(localized: "browser_certificate_valid"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        }
        Section {
            ForEach(chain) { link in
                Button { selected = link.id } label: {
                    Label {
                        Text(link.title)
                    } icon: {
                        Image(systemName: "seal")
                            .foregroundStyle(link.id == selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(link.id == selected ? Color.accentColor.opacity(0.12) : nil)
                .accessibilityAddTraits(link.id == selected ? .isSelected : [])
            }
        }
        ForEach(Self.sections(of: certificate), id: \.title) { section in
            Section(section.title) {
                ForEach(section.rows, id: \.label) { row in
                    LabeledContent(row.label) {
                        Text(row.value).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private struct Rows {
        let title: String
        let rows: [(label: String, value: String)]
    }

    private static func sections(of certificate: BrowserCertificate) -> [Rows] {
        func name(_ name: BrowserCertificate.Name) -> [(label: String, value: String)] {
            [
                (String(localized: "browser_certificate_common_name"), name.commonName),
                (String(localized: "browser_certificate_organization"), name.organization),
            ].compactMap { label, value in value.map { (label, $0) } }
        }
        let dates = [
            (String(localized: "browser_certificate_not_before"), certificate.notBefore),
            (String(localized: "browser_certificate_not_after"), certificate.notAfter),
        ].compactMap { label, date in date.map { (label: label, value: $0.formatted(date: .long, time: .omitted)) } }
        return [
            Rows(title: String(localized: "browser_certificate_issued_to"), rows: name(certificate.subject)),
            Rows(title: String(localized: "browser_certificate_issued_by"), rows: name(certificate.issuer)),
            Rows(title: String(localized: "browser_certificate_validity"), rows: dates),
            Rows(title: String(localized: "browser_certificate_fingerprint"), rows: [("SHA-256", certificate.sha256)]),
        ].filter { !$0.rows.isEmpty }
    }

    private static func summary(of certificate: BrowserCertificate) -> String {
        ([certificate.title] + sections(of: certificate).map { section in
            ([section.title] + section.rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
        }).joined(separator: "\n\n")
    }
}
