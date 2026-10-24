import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ClassTableShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.requestClassTableImport) private var requestImport
    @Environment(\.hostWindow) private var hostWindow
    #endif
    @Bindable var model: ClassTableShareModel

    private static let codeSide: CGFloat = 260

    #if os(iOS)
    static let openingDetent = PresentationDetent.height(440)
    #endif

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
                CopyLinkButton(link: model.link)
                Button(String(localized: "action_done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                // A sheet takes Escape only through a cancel button, and Done keeps Return.
                Button("") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            // The root presents the scanner, and only once this sheet is gone.
                            hostWindow.closePresentations { if $0 { requestImport() } }
                        } label: {
                            Label(String(localized: "class_table_import"), systemImage: "qrcode.viewfinder")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        CopyLinkButton(link: model.link)
                    }
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
                    } else {
                        Text(String(localized: "library_qr_generate_failed"))
                            .font(TigerDuckTheme.Typography.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(width: Self.codeSide, height: Self.codeSide)
                    }
                    Text(model.caption)
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(.secondary)
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

private struct CopyLinkButton: View {
    let link: String?
    @State private var isCopied = false
    @State private var copies = 0

    var body: some View {
        Button {
            guard let link else { return }
            #if canImport(UIKit)
            UIPasteboard.general.string = link
            #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            #endif
            AccessibilityNotification.Announcement(String(localized: "class_table_share_link_copied")).post()
            isCopied = true
            copies += 1
        } label: {
            Label(String(localized: "class_table_share_copy_link"), systemImage: isCopied ? "checkmark" : "link")
        }
        .labelStyle(.iconOnly)
        .help(String(localized: "class_table_share_copy_link"))
        .disabled(link == nil)
        .onChange(of: link) { isCopied = false }
        .task(id: copies) {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { isCopied = false }
        }
    }
}

extension View {
    func classTableShareSheet(model: Binding<ClassTableShareModel?>, loginGeneration: Int) -> some View {
        sheet(item: model) { model in
            #if os(iOS)
            ClassTableShareSheet(model: model)
                .presentationDetents([ClassTableShareSheet.openingDetent, .large])
            #else
            ClassTableShareSheet(model: model)
            #endif
        }
        .onChange(of: loginGeneration) { model.wrappedValue = nil }
    }
}
