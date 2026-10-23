#if os(iOS)
import AVFoundation
import PhotosUI
import SwiftUI
import Vision
import VisionKit

struct ClassTableImportScannerView: View {
    @Bindable var model: ClassTableImportModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera: Camera = .checking
    @State private var photo: PhotosPickerItem?

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
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(String(localized: "class_table_import_choose_photo"), systemImage: "photo.on.rectangle")
                }
                .controlSize(.large)
                .modifier(GlassTextButtonModifier())
                .disabled(!model.isIdle)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        model.cancel()
                        dismiss()
                    } label: {
                        Label(String(localized: "action_close"), systemImage: "xmark")
                    }
                }
            }
            .classTableImportPrompts(model, onConfirmScreen: false)
            .sheet(item: Binding(get: { model.pending }, set: { if $0 == nil { model.cancel() } })) { pending in
                ClassTableImportConfirmView(model: model, code: pending.code)
            }
        }
        .task { camera = await Self.cameraState() }
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
    }

    @ViewBuilder
    private var cameraView: some View {
        switch camera {
        case .checking, .missing:
            EmptyView()
        case .dataScanner:
            QRDataScanner(onCode: { model.scanned($0) }).ignoresSafeArea()
        case .captureSession:
            QRCaptureScanner(onCode: { model.scanned($0) }).ignoresSafeArea()
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
