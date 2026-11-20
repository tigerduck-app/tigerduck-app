#if DEBUG && os(iOS)
import SwiftUI

struct DevMailServerSection: View {
    let title: String
    let host: Binding<String>
    let port: Binding<Int>
    let scheme: Binding<MailTransportScheme>
    let placeholder: String

    var body: some View {
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
}

struct DevMailActiveSection: View {
    let active: MailServerConfig

    var body: some View {
        Section("In force now") {
            LabeledContent("Address domain", value: active.addressDomain)
            LabeledContent("IMAP", value: "\(active.imapHost):\(active.imapPort) · \(active.imapScheme.title)")
            LabeledContent("SMTP", value: "\(active.smtpHost):\(active.smtpPort) · \(active.smtpScheme.title)")
            LabeledContent("Overridden", value: active.isOverridden ? "Yes" : "No")
        }
    }
}

struct DevMailProbeOutputSection: View {
    let output: String
    let isTesting: Bool

    var body: some View {
        Section {
            if isTesting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Testing…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Text(output)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        } header: {
            Text("Test connection")
        }
    }
}
#endif
