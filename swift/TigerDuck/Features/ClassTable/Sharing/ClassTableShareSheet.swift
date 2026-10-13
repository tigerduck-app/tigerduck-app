import SwiftUI

/// The QR code of the user's class table, which is screenshotted and passed on, the caption saying
/// what it holds, and the term and format it is in.
struct ClassTableShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ClassTableShareModel

    /// Big enough to scan from a screenshot a chat app has halved: the longest code, a version 18
    /// symbol for 8 terms of 10 courses, still gets about four pixels a module there.
    private static let codeSide: CGFloat = 260

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text(String(localized: "class_table_share"))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            form
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "action_done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 520, idealHeight: 560)
        #else
        NavigationStack {
            form
                .navigationTitle(String(localized: "class_table_share"))
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "action_done")) { dismiss() }
                    }
                }
        }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    if let image = model.qrCode {
                        Image(image, scale: 1, label: Text(String(localized: "a11y_class_table_share_qr")))
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: Self.codeSide)
                            .clipShape(RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm, style: .continuous))
                    }
                    Text(model.caption)
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                Picker(String(localized: "class_table_semester_picker_label"), selection: $model.selection) {
                    ForEach(model.options, id: \.self) { option in
                        Text(model.label(for: option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Toggle(String(localized: "class_table_share_tat_compatible"), isOn: $model.isTATCompatible)
                    .disabled(!model.offersTAT)
            }
        }
        .formStyle(.grouped)
    }
}
