import SwiftUI
import UIKit

/// The imported class tables by placement: a tap renames one, a swipe deletes it, and its handle
/// moves it within or between placements. SwiftUI's `List` moves a row only within its own
/// `ForEach`, so the rows are a collection view list, whose reordering crosses sections.
struct ClassTableListView: View {
    let store: ImportedClassTableStore
    let userName: String
    @State private var dialogs: ShownPersonModel

    init(store: ImportedClassTableStore, userName: String) {
        self.store = store
        self.userName = userName
        _dialogs = State(initialValue: ShownPersonModel(store: store) { _, _, _ in nil })
    }

    var body: some View {
        ClassTableListRows(store: store, people: store.people, userName: userName, dialogs: dialogs)
            .ignoresSafeArea()
            .navigationTitle(String(localized: "class_table_list_title"))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ClassTablePersonDialogs(people: dialogs))
    }
}

struct ClassTableListRows: UIViewRepresentable {
    let store: ImportedClassTableStore
    let people: [ImportedPerson]
    let userName: String
    let dialogs: ShownPersonModel

    /// The user's own row has no id.
    nonisolated struct Row: Hashable {
        let id: UUID?
        let name: String
    }

    typealias Snapshot = NSDiffableDataSourceSnapshot<ImportedPerson.Placement, Row>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.trailingSwipeActionsConfigurationProvider = { [weak coordinator] in coordinator?.deleteAction(at: $0) }
        let layout = Layout { _, environment in NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment) }
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.delegate = coordinator
        coordinator.connect(view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.show(animated: view.window != nil)
    }

    /// A list layout aims a row only at other rows, so a section with none would take no row; a
    /// row moved between such a section's header and the next one goes into it.
    final class Layout: UICollectionViewCompositionalLayout {
        override func targetIndexPath(forInteractivelyMovingItem previousIndexPath: IndexPath, withPosition given: CGPoint) -> IndexPath {
            guard let view = collectionView else {
                return super.targetIndexPath(forInteractivelyMovingItem: previousIndexPath, withPosition: given)
            }
            // Once a row has left its section, the list hands an x of 0, beside the inset rows.
            let position = CGPoint(x: view.bounds.midX, y: given.y)
            let tops = (0..<view.numberOfSections).map { section in
                layoutAttributesForSupplementaryView(
                    ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)
                )?.frame.minY ?? .infinity
            }
            let empty = tops.indices.first { section in
                let next = tops.indices.contains(section + 1) ? tops[section + 1] : .infinity
                return view.numberOfItems(inSection: section) == 0 && position.y >= tops[section] && position.y < next
            }
            return empty.map { IndexPath(item: 0, section: $0) }
                ?? super.targetIndexPath(forInteractivelyMovingItem: previousIndexPath, withPosition: position)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: ClassTableListRows?
        private var dataSource: UICollectionViewDiffableDataSource<ImportedPerson.Placement, Row>?

        func connect(_ view: UICollectionView) {
            let cells = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
                var content = cell.defaultContentConfiguration()
                content.text = row.name
                cell.contentConfiguration = content
                cell.accessories = row.id == nil ? [] : [.reorder(displayed: .always)]
                cell.accessibilityTraits = row.id == nil ? .staticText : .button
                cell.accessibilityCustomActions = row.id.map { self?.actions(for: $0) ?? [] }
            }
            let headers = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
                elementKind: UICollectionView.elementKindSectionHeader
            ) { [weak self] header, _, indexPath in
                guard let placement = self?.dataSource?.sectionIdentifier(for: indexPath.section) else { return }
                var content = header.defaultContentConfiguration()
                content.text = String(localized: placement.title)
                header.contentConfiguration = content
            }
            let dataSource = UICollectionViewDiffableDataSource<ImportedPerson.Placement, Row>(collectionView: view) {
                $0.dequeueConfiguredReusableCell(using: cells, for: $1, item: $2)
            }
            dataSource.supplementaryViewProvider = { $0.dequeueConfiguredReusableSupplementary(using: headers, for: $2) }
            dataSource.reorderingHandlers.canReorderItem = { $0.id != nil }
            dataSource.reorderingHandlers.didReorder = { [weak self] in self?.reordered($0) }
            self.dataSource = dataSource
        }

        func show(animated: Bool) {
            guard let parent else { return }
            var snapshot = Snapshot()
            snapshot.appendSections(ImportedPerson.Placement.allCases)
            snapshot.appendItems([Row(id: nil, name: parent.userName)], toSection: .rotation)
            for person in parent.people {
                snapshot.appendItems([Row(id: person.id, name: person.nickname)], toSection: person.placement)
            }
            // A row's VoiceOver actions name the placements it is not in.
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource?.apply(snapshot, animatingDifferences: animated)
        }

        /// The moved row is the one a section gained, which a move within a section also shows.
        private func reordered(_ transaction: NSDiffableDataSourceTransaction<ImportedPerson.Placement, Row>) {
            for section in transaction.sectionTransactions {
                guard case .insert(_, let row, _)? = section.difference.insertions.first, let id = row.id else { continue }
                let next = section.finalSnapshot.items.drop { $0 != row }.dropFirst().first?.id
                move(id, to: section.sectionIdentifier, before: next)
                return
            }
        }

        private func move(_ id: UUID, to placement: ImportedPerson.Placement, before next: UUID?) {
            guard let parent else { return }
            let change = parent.store.move(id, to: placement, before: next, for: AccountSession.school.currentSignIn)
            if change == .failed { parent.dialogs.showsSaveFailed = true }
            if change != .saved { show(animated: true) }
        }

        private func person(_ id: UUID?) -> ImportedPerson? {
            parent?.people.first { $0.id == id }
        }

        func deleteAction(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let person = person(dataSource?.itemIdentifier(for: indexPath)?.id) else { return nil }
            let delete = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, done in
                self?.parent?.dialogs.startDeletingPerson(person)
                done(true)
            }
            delete.image = UIImage(systemName: "minus.circle")
            delete.backgroundColor = .systemRed
            delete.accessibilityLabel = String(localized: "class_table_delete_user")
            return UISwipeActionsConfiguration(actions: [delete])
        }

        func actions(for id: UUID) -> [UIAccessibilityCustomAction] {
            guard let placement = person(id)?.placement else { return [] }
            let moves = ImportedPerson.Placement.allCases.filter { $0 != placement }.map { target in
                UIAccessibilityCustomAction(name: String(localized: target.title)) { [weak self] _ in
                    self?.move(id, to: target, before: nil)
                    return true
                }
            }
            let delete = UIAccessibilityCustomAction(name: String(localized: "class_table_delete_user")) { [weak self] _ in
                guard let person = self?.person(id) else { return false }
                self?.parent?.dialogs.startDeletingPerson(person)
                return true
            }
            return moves + [delete]
        }

        /// The user's row stays first in the rotation.
        func collectionView(
            _ collectionView: UICollectionView,
            targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
            atCurrentIndexPath currentIndexPath: IndexPath,
            toProposedIndexPath proposedIndexPath: IndexPath
        ) -> IndexPath {
            let isAboveUser = proposedIndexPath.item == 0
                && dataSource?.sectionIdentifier(for: proposedIndexPath.section) == .rotation
            return isAboveUser ? IndexPath(item: 1, section: proposedIndexPath.section) : proposedIndexPath
        }

        func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
            dataSource?.itemIdentifier(for: indexPath)?.id != nil
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: true)
            guard let person = person(dataSource?.itemIdentifier(for: indexPath)?.id) else { return }
            parent?.dialogs.startRenamingPerson(person)
        }
    }
}

