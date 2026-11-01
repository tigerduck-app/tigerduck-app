#if os(iOS)
import AVFoundation
import Combine
import SwiftUI
import Vision
import VisionKit

/// VisionKit's scanner, which reports a code once when it comes into view: one still in view
/// after its alert or confirm screen closes is read again only once it leaves and comes back.
struct QRDataScanner: UIViewControllerRepresentable {
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

struct QRCaptureScanner: UIViewRepresentable {
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

/// VisionKit keeps its session private, so this takes the camera from the session's start
/// notification: locking any other camera for the torch freezes VisionKit's preview.
@Observable
final class ScannerTorch {
    struct Control: Equatable {
        let isOn: Bool
        let isEnabled: Bool

        init?(hasTorch: Bool, isAvailable: Bool, isActive: Bool) {
            guard hasTorch else { return nil }
            isOn = isActive
            isEnabled = isAvailable
        }
    }

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
