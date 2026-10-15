import OspreyMedia
import SwiftUI

/// The Subtitles chip's popover: a search field (focused on open), Off, the uploaded subtitles, then the automatic
/// captions (original-language track, English, the Mac's preferred languages, then the rest by name). Each row shows
/// the language's name and its code; the current choice has a check. Picking a row (or Return, which picks the first
/// match) closes the popover.
struct SubtitlePopover: View {
    let menu: SubtitleMenu
    let current: SubtitleChoice?
    let choose: (SubtitleChoice?) -> Void

    @State private var query = ""
    @State private var hovered: String?
    @FocusState private var searchFocused: Bool

    static let size = CGSize(width: 300, height: 420)

    var body: some View {
        let found = menu.filtered(query)
        VStack(spacing: 0) {
            searchField(firstMatch: firstMatch(found))
                .padding(10)
            Divider().opacity(0.6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    row(id: "off", name: "Off", code: nil, isChosen: current == nil) { choose(nil) }
                        .padding(.vertical, 4)
                    if !found.manual.isEmpty {
                        Section {
                            // Keyed by the whole choice: a code can be in both sections, and duplicate ids in one
                            // lazy stack leave a row blank.
                            ForEach(found.manual.map { SubtitleChoice(language: $0, isAuto: false) }, id: \.self) {
                                languageRow($0)
                            }
                        } header: {
                            SectionHeader(title: "Subtitles")
                        }
                    }
                    if !found.auto.isEmpty {
                        Section {
                            ForEach(found.auto.map { SubtitleChoice(language: $0, isAuto: true) }, id: \.self) {
                                languageRow($0)
                            }
                        } header: {
                            SectionHeader(title: "Auto-generated")
                        }
                    }
                    if found.manual.isEmpty && found.auto.isEmpty {
                        Text("No language matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { searchFocused = true }
    }

    private func searchField(firstMatch: SubtitleChoice?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            TextField("Search languages", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { if let firstMatch { choose(firstMatch) } }
                .accessibilityLabel("Search subtitle languages")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// What Return picks: the first listed language once something is typed.
    private func firstMatch(_ found: (manual: [String], auto: [String])) -> SubtitleChoice? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let code = found.manual.first { return SubtitleChoice(language: code, isAuto: false) }
        return found.auto.first.map { SubtitleChoice(language: $0, isAuto: true) }
    }

    private func languageRow(_ choice: SubtitleChoice) -> some View {
        row(id: (choice.isAuto ? "auto:" : "sub:") + choice.language, name: SubtitleMenu.name(choice.language),
            code: choice.language, isChosen: current == choice) { choose(choice) }
    }

    private func row(id: String, name: String, code: String?, isChosen: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(isChosen ? 1 : 0)
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let code {
                    Text(code)
                        .font(.system(size: 11.5).monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovered == id ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        .accessibilityLabel(code.map { "\(name), \($0)" } ?? name)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// "SUBTITLES" / "AUTO-GENERATED" above a section; pinned while its rows scroll.
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(.regularMaterial)
            .accessibilityAddTraits(.isHeader)
    }
}
