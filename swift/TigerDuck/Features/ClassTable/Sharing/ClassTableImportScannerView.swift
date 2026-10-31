#if os(iOS)
import AVFoundation
import Combine
import Defaults
import PhotosUI
import SwiftUI
import Vision
import VisionKit

struct ClassTableImportScannerView: View {
    @Bindable var model: ClassTableImportModel
    /// Takes the user's share sheet, for the presenter to show once this screen has closed.
    let onShare: (ClassTableShareModel) -> Void
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera: Camera = .checking
    @State private var photo: PhotosPickerItem?
    @State private var isEnteringLink = false
    @State private var enteredLink = ""
    @State private var ownTerms: [ClassTableShareModel.Term] = []
    @State private var torch = ScannerTorch()

    private enum Camera {
        case checking, dataScanner, captureSession, denied, missing
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                cameraView
                if model.isUpdating {
                    ProgressView().controlSize(.large)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: TigerDuckTheme.Spacing.lg) {
                    torchToggle
                    otherSources.disabled(!model.isIdle)
                }
                .labelStyle(.iconOnly)
                .controlSize(.large)
                .modifier(GlassIconButtonModifier())
                // Past this size three circles outgrow a 375pt-wide phone.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)
            }
            .environment(\.colorScheme, .dark)
            .navigationTitle(String(localized: "class_table_import"))
            .navigationBarTitleDisplayMode(.inline)
            // The bar takes its dark scheme only over a background it shows.
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if let studentId = app.authService.storedStudentId, !ownTerms.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.cancel()
                            onShare(ClassTableShareModel(
                                studentId: studentId, terms: ownTerms, semesterLabel: ClassTableImportSummary.semesterLabel
                            ))
                            dismiss()
                        } label: {
                            Label(String(localized: "class_table_share"), systemImage: "qrcode")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.cancel()
                        dismiss()
                    } label: {
                        Label(String(localized: "action_close"), systemImage: "xmark")
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .alert(String(localized: "class_table_import_enter_link"), isPresented: $isEnteringLink) {
                TextField(String(localized: "class_table_import_link_placeholder"), text: $enteredLink)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(String(localized: "action_cancel"), role: .cancel) {}
                Button(String(localized: "action_import")) { model.linkOpened(enteredLink) }
                    .disabled(enteredLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .classTableImportPrompts(model, onConfirmScreen: false)
            .sheet(item: Binding(get: { model.pending }, set: { if $0 == nil { model.cancel() } })) { pending in
                ClassTableImportConfirmView(model: model, code: pending.code)
            }
        }
        .task { camera = await Self.cameraState() }
        .onAppear { ownTerms = Self.ownTerms(studentId: app.authService.storedStudentId) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, camera == .denied else { return }
            Task { camera = await Self.cameraState() }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            model.readImage(load: { await Self.data(of: item) })
        }
        .onChange(of: model.isFinished) { _, isFinished in
            if isFinished { dismiss() }
        }
        .onReceive(Self.sessionNotes(AVCaptureSession.didStartRunningNotification)) {
            torch.sessionStarted($0.object as? AVCaptureSession)
        }
        .onReceive(Self.sessionNotes(AVCaptureSession.didStopRunningNotification)) { _ in torch.sessionStopped() }
        .onDisappear { torch.sessionStopped() }
    }

    /// A session can post these off the main thread.
    private static func sessionNotes(_ name: Notification.Name) -> some Publisher<Notification, Never> {
        NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
    }

    @ViewBuilder
    private var cameraView: some View {
        switch camera {
        case .checking, .missing:
            EmptyView()
        case .dataScanner:
            QRDataScanner(onCode: scanned).ignoresSafeArea()
        case .captureSession:
            QRCaptureScanner(onCode: scanned).ignoresSafeArea()
        case .denied:
            VStack(spacing: TigerDuckTheme.Spacing.md) {
                Text(String(localized: "class_table_import_camera_denied"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button(String(localized: "action_go_to_settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .modifier(GlassTextButtonModifier())
            }
            .padding(TigerDuckTheme.Spacing.xl)
        }
    }

    @ViewBuilder
    private var torchToggle: some View {
        if let control = torch.control {
            Toggle(isOn: Binding(get: { control.isOn }, set: { torch.turn($0) })) {
                IconLabel(
                    title: String(localized: "class_table_import_flashlight"),
                    systemImage: control.isOn ? "flashlight.on.fill" : "flashlight.off.fill"
                )
            }
            .toggleStyle(.button)
            .disabled(!control.isEnabled)
        }
    }

    @ViewBuilder
    private var otherSources: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            IconLabel(title: String(localized: "class_table_import_choose_photo"), systemImage: "photo.on.rectangle")
        }
        Button {
            enteredLink = ""
            isEnteringLink = true
        } label: {
            IconLabel(title: String(localized: "class_table_import_enter_link"), systemImage: "keyboard")
        }
    }

    /// A code the camera finds while a link is typed would open its screen under the alert.
    private func scanned(_ text: String) -> Bool {
        !isEnteringLink && model.scanned(text)
    }

    /// The terms the class table's share sheet offers, from the cache; none when the user has
    /// nothing to share or a student ID no code can hold.
    private static func ownTerms(studentId: String?) -> [ClassTableShareModel.Term] {
        guard let studentId, ClassTableShareCode.isUpperAlphanumerics(studentId.uppercased()[...]) else { return [] }
        let semester = SchoolTerms.selected(storedPick: Defaults[.classTableSelectedSemester])
        return ClassTableShareModel.terms(in: ClassTableViewModel.semesterOptions(including: semester))
    }

    private static func cameraState() async -> Camera {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        default:
            return .denied
        }
        if DataScannerViewController.isSupported, DataScannerViewController.isAvailable { return .dataScanner }
        return AVCaptureDevice.default(for: .video) == nil ? .missing : .captureSession
    }

    private static func data(of item: PhotosPickerItem) async -> Data? {
        do {
            return try await item.loadTransferable(type: Data.self)
        } catch {
            AppLogger.captureError(error, context: ["phase": "classTableImport.loadPhoto"])
            return nil
        }
    }
}

private struct IconLabel: View {
    let title: String
    let systemImage: String
    /// One frame for every symbol, so narrow and wide ones get the same circle. It lives here to
    /// scale with the row's capped text size.
    @ScaledMetric(relativeTo: .title3) private var side: CGFloat = 28

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).font(.title3).frame(width: side, height: side)
        }
    }
}

private struct GlassIconButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }
}

#endif
