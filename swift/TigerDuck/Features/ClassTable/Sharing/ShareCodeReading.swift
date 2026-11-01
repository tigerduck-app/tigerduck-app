import Foundation
import Vision

nonisolated enum ShareCodeReading: Equatable {
    case notShareCode
    case invalid
    case needsUpdate
    case code(ClassTableShareCode)

    var code: ClassTableShareCode? {
        if case .code(let code) = self { code } else { nil }
    }

    init(_ text: String) {
        do {
            self = .code(try ClassTableShareCode.decode(text))
        } catch ClassTableShareCodeError.unknownPrefix {
            self = .notShareCode
        } catch ClassTableShareCodeError.unknownVersion, ClassTableShareCodeError.unknownType {
            self = .needsUpdate
        } catch {
            AppLogger.breadcrumb("share code refused: \(error)", category: "classTableImport")
            self = .invalid
        }
    }

    static func qrPayloads(in data: Data) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        #if targetEnvironment(simulator)
        // The simulator cannot create the inference context the later revisions run in.
        request.revision = 1
        #endif
        do {
            try VNImageRequestHandler(data: data).perform([request])
        } catch {
            AppLogger.captureError(error, context: ["phase": "classTableImport.detectBarcodes"])
            return []
        }
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }

    static func data(fileAt url: URL) async -> Data? {
        await Task.detached { () -> Data? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                return try Data(contentsOf: url)
            } catch {
                AppLogger.captureError(error, context: ["phase": "classTableImport.readFile"])
                return nil
            }
        }.value
    }
}
