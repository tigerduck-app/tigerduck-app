#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct MacClassTableImport: ViewModifier {
    @Binding var model: ClassTableImportModel?
    @Binding var showsPicker: Bool
    let request: () -> Void

    @Environment(AppEnvironment.self) private var app

    func body(content: Content) -> some View {
        content
            .environment(\.requestClassTableImport, request)
            .fileImporter(isPresented: $showsPicker, allowedContentTypes: [.image]) { result in
                let model = ClassTableImportModel.live(authService: app.authService)
                self.model = model
                switch result {
                case .success(let url):
                    Task { await model.readImage(fileAt: url) }
                case .failure(let error):
                    AppLogger.captureError(error, context: ["phase": "classTableImport.pickFile"])
                    Task { await model.readImage(nil) }
                }
            }
            .classTableImportPrompts(model, onConfirmScreen: false)
            .sheet(item: Binding(get: { model?.pending }, set: { if $0 == nil { model?.cancel() } })) { pending in
                if let model {
                    ClassTableImportConfirmView(model: model, code: pending.code)
                }
            }
            .onChange(of: model?.isFinished) { _, isFinished in
                if isFinished == true { model = nil }
            }
            .onChange(of: HeldShareLink.shared.link?.id, initial: true) { openHeldLink() }
            .onChange(of: HeldShareLink.mayOpen(in: app)) { openHeldLink() }
    }

    private func openHeldLink() {
        guard let text = HeldShareLink.shared.take(in: app) else { return }
        if let model, !model.isFinished {
            model.linkOpened(text)
            return
        }
        let model = ClassTableImportModel.live(authService: app.authService)
        self.model = model
        model.linkOpened(text)
    }
}
#endif
