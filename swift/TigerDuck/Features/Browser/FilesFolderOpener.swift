import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iOS documents no way to open the Files app at a folder (https://developer.apple.com/forums/thread/751391);
/// Chrome for iOS builds a `shareddocuments://` link for it, in `GetFilesAppUrl()` of
/// https://chromium.googlesource.com/chromium/src/+/711ab9bc/ios/chrome/browser/download/external_app_util.mm
struct FilesFolderOpener {
    enum Route: Equatable { case filesApp, picker }

    var canOpen: (URL) -> Bool = { UIApplication.shared.canOpenURL($0) }
    var open: (URL) async -> Bool = { await UIApplication.shared.open($0) }

    func route(to folder: URL) async -> Route {
        guard let link = URL(string: "shareddocuments://" + folder.path(percentEncoded: true)), canOpen(link), await open(link)
        else { return .picker }
        return .filesApp
    }
}

struct FilesFolderPicker: UIViewControllerRepresentable {
    let folder: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.directoryURL = folder
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}
}
