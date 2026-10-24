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
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera: Camera = .checking
    @State private var photo: PhotosPickerItem?
    @State private var isEnteringLink = false
    @State private var enteredLink = ""
    @State private var ownTerms: [ClassTableShareModel.Term] = []
    @State private var torch = ScannerTorch()
    /// One frame for every symbol, so narrow and wide ones get the same circle.
    @ScaledMetric(relativeTo: .title3) private var iconSide: CGFloat = 28

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
                if let studentId = appState.authService.storedStudentId, !ownTerms.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.cancel()
                            onShare(ClassTableShareModel(
                                studentId: studentId, terms: ownTerms, semesterLabel: ClassTableImportModel.semesterLabel
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
        .onAppear { ownTerms = Self.ownTerms(studentId: appState.authService.storedStudentId) }
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
                iconLabel(
                    String(localized: "class_table_import_flashlight"),
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
            iconLabel(String(localized: "class_table_import_choose_photo"), systemImage: "photo.on.rectangle")
        }
        Button {
            enteredLink = ""
            isEnteringLink = true
        } label: {
            iconLabel(String(localized: "class_table_import_enter_link"), systemImage: "keyboard")
        }
    }

    private func iconLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).font(.title3).frame(width: iconSide, height: iconSide)
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
        let semester = SemesterCatalog.selectedSemester(storedPick: Defaults[.classTableSelectedSemester])
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

/// VisionKit's scanner, which reports a code once when it comes into view: one still in view
/// after its alert or confirm screen closes is read again only once it leaves and comes back.
private struct QRDataScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Bool

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            AppLogger.captureError(error, context: ["phase": "classTableImport.startScanning"])
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Bool

        init(onCode: @escaping (String) -> Bool) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for case .barcode(let barcode) in addedItems {
                if let payload = barcode.payloadStringValue, onCode(payload) { return }
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            AppLogger.captureError(error, context: ["phase": "classTableImport.scannerUnavailable"])
        }
    }
}

private struct QRCaptureScanner: UIViewRepresentable {
    let onCode: (String) -> Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.start(in: view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Bool
        private let session = AVCaptureSession()
        /// `startRunning` blocks until the camera is up, so it runs off the main thread.
        private let sessionQueue = DispatchQueue(label: "org.ntust.app.TigerDuck.classTableImport.camera")
        private var filter = RepeatedCodeFilter()
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        private weak var view: PreviewView?

        init(onCode: @escaping (String) -> Bool) {
            self.onCode = onCode
        }

        func start(in view: PreviewView) {
            guard let device = AVCaptureDevice.default(for: .video) else { return }
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                AppLogger.captureError(error, context: ["phase": "classTableImport.cameraInput"])
                return
            }
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                AppLogger.breadcrumb("camera session refused its input or output", category: "classTableImport")
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            // The types can be set only once the output is in a session with a camera.
            output.metadataObjectTypes = [.qr]
            output.setMetadataObjectsDelegate(self, queue: .main)

            self.view = view
            view.previewLayer.session = session
            let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: view.previewLayer)
            rotationObservation = rotation.observe(
                \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                Task { @MainActor [weak self] in self?.view?.previewLayer.connection?.videoRotationAngle = angle }
            }
            self.rotation = rotation

            sessionQueue.async { [session] in session.startRunning() }
        }

        func stop() {
            rotationObservation = nil
            sessionQueue.async { [session] in session.stopRunning() }
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let payloads = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            MainActor.assumeIsolated { take(payloads, at: Date()) }
        }

        private func take(_ payloads: [String], at now: Date) {
            for payload in payloads where filter.isNew(payload, at: now) {
                if onCode(payload) { return }
            }
        }
    }
}

/// The torch of the camera a running scanner session uses. VisionKit keeps its session private,
/// so this takes the camera from the session's start notification: locking any other camera for
/// the torch freezes VisionKit's preview.
@Observable
final class ScannerTorch {
    struct Control: Equatable {
        let isOn: Bool
        let isEnabled: Bool

        /// Nil for a camera without a torch; one too hot to light keeps its toggle, disabled.
        init?(hasTorch: Bool, isAvailable: Bool, isActive: Bool) {
            guard hasTorch else { return nil }
            isOn = isActive
            isEnabled = isAvailable
        }
    }

    /// Nil hides the toggle.
    private(set) var control: Control?
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func sessionStarted(_ session: AVCaptureSession?) {
        device = session?.inputs.lazy
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first { $0.hasMediaType(.video) }
        // The system can switch the torch off itself, as when the phone overheats.
        observations = [\AVCaptureDevice.isTorchActive, \AVCaptureDevice.isTorchAvailable].compactMap {
            device?.observe($0) { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        refresh()
    }

    func sessionStopped() {
        observations = []
        if device?.torchMode != .off { turn(false) }
        device = nil
        refresh()
    }

    func turn(_ isOn: Bool) {
        let mode: AVCaptureDevice.TorchMode = isOn ? .on : .off
        guard let device, device.isTorchModeSupported(mode) else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = mode
            device.unlockForConfiguration()
        } catch {
            AppLogger.captureError(error, context: ["phase": "classTableImport.torch"])
        }
        refresh()
    }

    private func refresh() {
        control = device.flatMap {
            Control(hasTorch: $0.hasTorch, isAvailable: $0.isTorchAvailable, isActive: $0.isTorchActive)
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

/// Lets a code through once while it stays in view. AVFoundation reports a code on every frame
/// that shows it, and without this a code still in front of the camera would open its confirm
/// screen again the moment it was cancelled.
struct RepeatedCodeFilter {
    static let gap: TimeInterval = 1

    private var lastSeen: [String: Date] = [:]

    mutating func isNew(_ payload: String, at now: Date) -> Bool {
        let seen = lastSeen[payload]
        lastSeen = lastSeen.filter { now.timeIntervalSince($0.value) <= Self.gap }
        lastSeen[payload] = now
        guard let seen else { return true }
        return now.timeIntervalSince(seen) > Self.gap
    }
}
#endif
