import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The class table tab's long press, which opens the switcher next to the tab, and double tap,
/// which goes back to the class table shown before, or within 3 s of the last double tap shows
/// the next one. `TabView` has no gesture API for its items, so both go on the
/// system tab bar, where the tab is found by its title. Put it behind the `TabView`.
struct ClassTableTabBarGestures: UIViewRepresentable {
    let tabTitle: String?
    let isShowingClassTable: Bool
    let store: ImportedClassTableStore
    let userName: String
    let showClassTable: () -> Void

    func makeCoordinator() -> ClassTableTabBarHandler {
        ClassTableTabBarHandler(store: store)
    }

    func makeUIView(context: Context) -> TabBarFinder {
        TabBarFinder(handler: context.coordinator)
    }

    func updateUIView(_ view: TabBarFinder, context: Context) {
        let handler = context.coordinator
        handler.tabTitle = tabTitle
        handler.isShowingClassTable = isShowingClassTable
        handler.store = store
        handler.userName = userName
        handler.showClassTable = showClassTable
        handler.requestImport = context.environment.requestClassTableImport
        view.attach()
        if isShowingClassTable {
            DispatchQueue.main.async { [weak handler] in handler?.logIfTabMissing() }
        }
    }

    static func dismantleUIView(_ view: TabBarFinder, coordinator: ClassTableTabBarHandler) {
        coordinator.detach()
    }
}

/// Hands the handler the window's tab bar controller, which the `TabView` may add after this view
/// joins the window.
final class TabBarFinder: UIView {
    let handler: ClassTableTabBarHandler

    init(handler: ClassTableTabBarHandler) {
        self.handler = handler
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attach()
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attach()
    }

    func attach() {
        guard let controller = Self.tabBarController(in: window?.rootViewController) else { return }
        handler.attach(to: controller)
    }

    private static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { tabBarController(in: $0) }.first
    }
}

final class ClassTableTabBarHandler: NSObject, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
    var tabTitle: String?
    var isShowingClassTable = false
    var store: ImportedClassTableStore
    var userName = ""
    var showClassTable: () -> Void = {}
    var requestImport: () -> Void = {}

    private(set) weak var bar: UIView?
    private var menuInteraction: UIContextMenuInteraction?
    private var doubleTap: ClassTableTabDoubleTap?
    private var hasLoggedMissingTab = false
    private var lastDoubleTap: ContinuousClock.Instant?

    static let cyclingWindow: Duration = .seconds(3)

    init(store: ImportedClassTableStore) {
        self.store = store
    }

    /// The controller's tab bar, or on iPad, where that bar stays out of the window, the list of
    /// tabs in the floating bar at the top.
    func attach(to controller: UITabBarController) {
        let tabBar = controller.tabBar
        let shown: UIView? = tabBar.window != nil ? tabBar : floatingTabs(in: controller)
        guard let bar = shown, bar !== self.bar else { return }
        detach()
        self.bar = bar
        let interaction = UIContextMenuInteraction(delegate: self)
        bar.addInteraction(interaction)
        menuInteraction = interaction

        let doubleTap = ClassTableTabDoubleTap(target: self, action: #selector(didDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.isShowingClassTable = { [weak self] in self?.isShowingClassTable ?? false }
        doubleTap.delaysTouchesEnded = false
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        bar.addGestureRecognizer(doubleTap)
        self.doubleTap = doubleTap
    }

    func detach() {
        if let menuInteraction { bar?.removeInteraction(menuInteraction) }
        if let doubleTap { bar?.removeGestureRecognizer(doubleTap) }
        menuInteraction = nil
        doubleTap = nil
        bar = nil
    }

    func classTableTabFrame() -> CGRect? {
        guard let bar, let item = classTableItem(in: bar) else { return nil }
        return item.convert(item.bounds, to: bar)
    }

    private func classTableItem(in view: UIView, skipping skipped: Set<ObjectIdentifier> = []) -> UIView? {
        tabTitle.flatMap { Self.item(titled: $0, in: view, skipping: skipped) }
    }

    private func floatingTabs(in controller: UITabBarController) -> UIView? {
        let pages = Set(controller.children.compactMap(\.viewIfLoaded).map(ObjectIdentifier.init))
        let item = classTableItem(in: controller.view, skipping: pages)
        return item.flatMap { sequence(first: $0, next: \.superview).first { $0 is UICollectionView } }
    }

    /// Finding the tab leans on how UIKit draws its bar, so a miss while the class table tab is
    /// selected, when the bar must show it, is logged once.
    func logIfTabMissing() {
        guard tabTitle != nil, classTableTabFrame() == nil, !hasLoggedMissingTab else { return }
        hasLoggedMissingTab = true
        AppLogger.breadcrumb("class table tab not found", category: "classTableTabBar")
    }

    func doubleTapped(at location: CGPoint, startedOnClassTable: Bool, now: ContinuousClock.Instant = .now) {
        guard startedOnClassTable, classTableTabFrame()?.contains(location) == true else { return }
        defer { lastDoubleTap = now }
        if let lastDoubleTap, now - lastDoubleTap <= Self.cyclingWindow {
            store.showNext()
        } else {
            store.showPrevious()
        }
    }

    static func menu(
        _ sections: [[ClassTableSwitcherEntry]],
        opensUpward: Bool,
        choose: @escaping (ClassTableSwitcherEntry) -> Void
    ) -> UIMenu {
        let ordered = opensUpward ? sections : sections.reversed().map { $0.reversed() }
        return UIMenu(children: ordered.map { section in
            UIMenu(options: .displayInline, children: section.map { entry in
                UIAction(
                    title: entry.title,
                    image: entry == .importClassTable ? UIImage(systemName: "plus") : nil,
                    state: entry.isShown ? .on : .off
                ) { _ in choose(entry) }
            })
        })
    }

    @objc private func didDoubleTap(_ recognizer: ClassTableTabDoubleTap) {
        guard recognizer.state == .ended else { return }
        doubleTapped(at: recognizer.location(in: bar), startedOnClassTable: recognizer.startedOnClassTable)
    }

    /// The bar's items have no public view, so a tab is the view whose label shows its title. iOS 26
    /// draws an iPhone tab twice, a selected look under the plain one, and the last match is plain.
    private static func item(titled title: String, in view: UIView, skipping skipped: Set<ObjectIdentifier>) -> UIView? {
        var found: UIView?
        for subview in view.subviews where !subview.isHidden && !skipped.contains(ObjectIdentifier(subview)) {
            if (subview as? UILabel)?.text == title {
                found = view
            } else if let deeper = item(titled: title, in: subview, skipping: skipped) {
                found = deeper
            }
        }
        return found
    }

    private func preview() -> UITargetedPreview? {
        guard let bar, let item = classTableItem(in: bar), item.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        guard Self.isAtBottom(bar) else { return UITargetedPreview(view: item, parameters: parameters) }
        // The system lifts a preview clear of the home indicator, which would draw the tab a second
        // time above the bar, so a clear stand-in anchors the menu on the tab instead.
        parameters.shadowPath = UIBezierPath()
        let frame = item.convert(item.bounds, to: bar)
        return UITargetedPreview(
            view: UIView(frame: CGRect(origin: .zero, size: frame.size)),
            parameters: parameters,
            target: UIPreviewTarget(container: bar, center: CGPoint(x: frame.midX, y: frame.midY))
        )
    }

    private static func isAtBottom(_ bar: UIView) -> Bool {
        let window = bar.window
        return bar.convert(bar.bounds, to: window).midY > (window?.bounds.midY ?? 0)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let bar, classTableTabFrame()?.contains(location) == true else { return nil }
        let opensUpward = Self.isAtBottom(bar)
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return Self.menu(
                ClassTableSwitcherEntry.sections(in: self.store, userName: self.userName),
                opensUpward: opensUpward
            ) { [weak self] entry in
                guard let self else { return }
                self.showClassTable()
                DispatchQueue.main.async { entry.choose(in: self.store, requestImport: self.requestImport) }
            }
        }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        preview()
    }

    /// The bar's own recognizers select and drag between tabs; the double tap only watches.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

final class ClassTableTabDoubleTap: UITapGestureRecognizer {
    var isShowingClassTable: () -> Bool = { false }
    private(set) var startedOnClassTable = false
    private var hasStarted = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if !hasStarted {
            hasStarted = true
            startedOnClassTable = isShowingClassTable()
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        hasStarted = false
    }
}
