import SwiftUI

/// Reusable multi-select picker. Used for both org and tag selection in
/// the subscription rule editor. Items are sourced from the live taxonomy
/// so this view stays agnostic of which dimension it is picking.
struct BulletinTaxonomyPickerView: View {
    let title: String
    let options: [(id: String, label: String)]
    @Binding var selected: Set<String>
    var emptyMeansAll: Bool = true

    var body: some View {
        List {
            if emptyMeansAll {
                Section {
                    Text(String(localized: "bulletin_taxonomy_picker_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(options, id: \.id) { option in
                    Button {
                        toggle(option.id)
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            if selected.contains(option.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        // Without contentShape, taps in the Spacer / trailing
                        // padding fall through to the underlying List row
                        // (no-op) instead of the Button. Make the whole row
                        // hit-testable so users don't have to land on the
                        // text glyphs to toggle selection.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !selected.isEmpty {
                Section {
                    Button(role: .destructive) {
                        selected.removeAll()
                    } label: {
                        Text(String(format: String(localized: "bulletin_taxonomy_clear_selection"), selected.count))
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }
}
