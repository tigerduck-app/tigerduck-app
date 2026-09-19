#if DEBUG && os(iOS)
import SwiftUI

/// Developer-only screen for pointing School Mail at a mail server that is not the school's.
/// Reached from `Settings → Developer → Email`; the row, this file and the store behind it are
/// all `#if DEBUG`, so a Release build has no override to read and no screen to reach.
///
/// Nothing here takes effect until **Apply**. Applying an actual change signs the mail account
/// out and wipes its caches, markers and notifications — see `DevMailServerSettings`, which
/// explains why — so the screen says so up front rather than surprising anyone.
struct DevMailServerView: View {
    private let settings = DevMailServerSettings.shared
    @State private var status: String?
    @State private var probeOutput: String?
    @State private var probeTask: Task<Void, Never>?

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle("Use a different mail server", isOn: $settings.draft.isEnabled)
            } header: {
                Text("Override")
            } footer: {
                Text("Off is the real school server: \(MailServerConfig.school.imapHost), IMAP \(MailServerConfig.school.imapPort) / SMTP \(MailServerConfig.school.smtpPort), implicit TLS. Nothing on this screen changes anything until you tap Apply.")
            }

            Section {
                TextField("example.com", text: $settings.draft.addressDomain)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            } header: {
                Text("Address domain")
            } footer: {
                Text("Replaces mail.ntust.edu.tw in your own address, in the Message-ID of anything you send, and in the rules that decide the External badge and the mistyped-recipient warning. Sign in with your full address as the username if the server wants one.")
            }

            serverSection(
                title: "IMAP",
                host: $settings.draft.imapHost,
                port: $settings.draft.imapPort,
                scheme: $settings.draft.imapScheme,
                placeholder: "imap.example.com"
            )

            serverSection(
                title: "SMTP",
                host: $settings.draft.smtpHost,
                port: $settings.draft.smtpPort,
                scheme: $settings.draft.smtpScheme,
                placeholder: "smtp.example.com"
            )

            if let clamped = clampedHosts {
                Section {
                    Label(
                        "\(clamped) is a pinned NTUST host, so it stays on implicit TLS whatever this screen says. The school connection cannot be downgraded from here.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                }
            }

            Section {
                Button("Apply") { apply() }
                    .disabled(!canApply || isTesting)
                if isTesting {
                    Button("Cancel test", role: .cancel) { cancelTest() }
                } else {
                    Button("Test connection") { test() }
                }
                Button("Reset to the school server", role: .destructive) { reset() }
                    .disabled(!settings.stored.isEnabled || isTesting)
            } footer: {
                Text("Applying a change signs School Mail out, wipes its cached mail, folder list, unread markers and notifications, and clears the saved password — none of that state records which server it came from, so it cannot be kept. While the override is on, TigerDuck will not create the Mail2000 folders 寄件備份匣 / 草稿匣 / 回收筒 on your test account; saving a draft fails instead, and sent copies and deletes fall back.\n\nTest connection changes nothing and applies nothing: it dials what is on screen right now and reports DNS, TCP, TLS, the client's own handshake and LOGIN separately, each with the error that was actually thrown rather than the five sentences the app shows elsewhere.")
            }

            Section("In force now") {
                LabeledContent("Address domain", value: active.addressDomain)
                LabeledContent("IMAP", value: "\(active.imapHost):\(active.imapPort) · \(active.imapScheme.title)")
                LabeledContent("SMTP", value: "\(active.smtpHost):\(active.smtpPort) · \(active.smtpScheme.title)")
                LabeledContent("Overridden", value: active.isOverridden ? "Yes" : "No")
            }

            if let probeOutput {
                Section {
                    if isTesting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Testing…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Selectable and monospaced: the whole point of this output is that it can be
                    // copied somewhere else, column-aligned, exactly as it reads here.
                    Text(probeOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Test connection")
                }
            }

            if let status {
                Section {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Email")
        .onDisappear { probeTask?.cancel() }
    }

    private var active: MailServerConfig { settings.effectiveConfig }

    /// Apply is offered only for a configuration that is both complete and actually different
    /// from the one in force — a disabled button says "nothing would happen" more clearly than
    /// a button that does nothing.
    private var canApply: Bool {
        guard settings.draft != settings.stored else { return false }
        return !settings.draft.isEnabled || settings.draft.normalized != nil
    }

    /// The hosts on this screen that `MailServerConfig.transportScheme(for:requested:)` will
    /// hold at implicit TLS however the pickers are set.
    private var clampedHosts: String? {
        let hosts = [settings.draft.imapHost, settings.draft.smtpHost]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && MailServerConfig.isPinnedHost($0) }
        guard !hosts.isEmpty else { return nil }
        return Array(Set(hosts)).sorted().joined(separator: ", ")
    }

    @ViewBuilder
    private func serverSection(
        title: String,
        host: Binding<String>,
        port: Binding<Int>,
        scheme: Binding<MailTransportScheme>,
        placeholder: String
    ) -> some View {
        Section(title) {
            TextField(placeholder, text: host)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            TextField("Port", value: port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            Picker("TLS", selection: scheme) {
                ForEach(MailTransportScheme.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func apply() {
        if settings.apply() {
            status = "Applied. Signed out, caches and notifications cleared. Sign in again on the School Mail page."
        } else {
            status = "Saved — the effective configuration did not change, so nothing was signed out."
        }
    }

    private var isTesting: Bool { probeTask != nil }

    /// Tests the **draft** — what is on screen — rather than what is applied. Diagnosing a server
    /// before committing to it is the point: applying signs the account out, so a developer who
    /// has to apply first in order to find out why a server will not connect has already paid for
    /// the answer before getting it.
    ///
    /// The credentials are read here, at the call site, so nothing below the UI reaches into
    /// `MailAccountManager` or the Keychain on its own. Both reads are reads: this button does not
    /// sign in, sign out, clear anything or write anything.
    private func test() {
        probeTask?.cancel()
        probeTask = nil
        if let refusal = DevMailConnectionProbe.refusal(for: settings.draft) {
            probeOutput = refusal
            return
        }
        let config = MailServerConfig.resolve(override: settings.draft)
        let credentials = DevMailConnectionProbe.credentials(
            username: MailAccountManager.shared.studentID,
            password: MailCredentialStore().password(),
            appliedIsOverridden: settings.effectiveConfig.isOverridden
        )
        probeOutput = "IMAP \(config.imapHost):\(config.imapPort) · SMTP \(config.smtpHost):\(config.smtpPort)"
        probeTask = Task {
            let reports = await DevMailConnectionProbe.run(config: config, credentials: credentials)
            guard !Task.isCancelled else { return }
            probeOutput = DevMailConnectionProbe.text(of: reports)
            probeTask = nil
        }
    }

    /// Stops waiting. A stage already in flight is bounded by its own timeout and ends on its own
    /// — SwiftMail's commands ignore cancellation — but nothing reads its result once this ran.
    private func cancelTest() {
        probeTask?.cancel()
        probeTask = nil
        probeOutput = [probeOutput, "Cancelled."].compactMap { $0 }.joined(separator: "\n")
    }

    private func reset() {
        if settings.resetToSchoolServer() {
            status = "Back on the school server. Signed out, caches and notifications cleared."
        } else {
            status = "Already on the school server."
        }
    }
}
#endif
