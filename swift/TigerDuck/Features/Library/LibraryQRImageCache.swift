#if os(iOS)
import UIKit

@MainActor
final class LibraryQRImageCache {
    static let shared = LibraryQRImageCache()

    private var cachedPayload: String?
    private var cachedImage: UIImage?

    private var memoryWarningObserver: (any NSObjectProtocol)?

    init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { LibraryQRImageCache.shared.clear() }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func image(for payload: String) -> UIImage? {
        cachedPayload == payload ? cachedImage : nil
    }

    func store(_ image: UIImage, for payload: String) {
        cachedPayload = payload
        cachedImage = image
    }

    func clear() {
        cachedPayload = nil
        cachedImage = nil
    }
}
#endif
