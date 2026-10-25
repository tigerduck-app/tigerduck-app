import SwiftUI

struct BrowserFindBar: View {
    @Bindable var find: BrowserFind
    @FocusState private var focused: Bool

    private static let height: CGFloat = 48
    private static let pause: Duration = .milliseconds(250)

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Button { find.end() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                    .frame(width: Self.height, height: Self.height)
            }
            .foregroundStyle(.primary)
            .browserGlass(in: Circle())
            .accessibilityLabel(String(localized: "browser_find_done"))

            HStack(spacing: 4) {
                modeMenu
                TextField(String(localized: "browser_find_field"), text: $find.query)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await find.next() } }
                Text(find.position)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 4)
            .padding(.trailing, 14)
            .frame(height: Self.height)
            .browserGlass(in: Capsule())

            HStack(spacing: 0) {
                step("chevron.up", String(localized: "browser_find_previous")) { await find.previous() }
                Divider().frame(height: 24)
                step("chevron.down", String(localized: "browser_find_next")) { await find.next() }
            }
            .frame(height: Self.height)
            .browserGlass(in: Capsule())
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .onAppear { focused = true }
        // Searches once typing pauses rather than on every keystroke.
        .task(id: [find.query, find.mode.rawValue]) {
            do { try await Task.sleep(for: Self.pause) } catch { return }
            await find.search()
        }
    }

    private var modeMenu: some View {
        Menu {
            Picker(selection: $find.mode) {
                ForEach(BrowserFind.Mode.allCases, id: \.self) { mode in
                    Text(Self.name(of: mode)).tag(mode)
                }
            } label: {
                EmptyView()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(height: 40)
            .contentShape(.rect)
        }
        .accessibilityLabel(Self.name(of: find.mode))
    }

    private func step(_ symbol: String, _ label: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: Self.height)
                .contentShape(.rect)
        }
        .disabled(find.count == 0)
        .accessibilityLabel(label)
    }

    private static func name(of mode: BrowserFind.Mode) -> String {
        switch mode {
        case .plain: String(localized: "browser_find_plain")
        case .regex: String(localized: "browser_find_regex")
        }
    }
}
