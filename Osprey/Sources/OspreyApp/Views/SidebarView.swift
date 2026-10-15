import SwiftUI

/// The library and categories on a floating glass panel, with the speed limit at the bottom.
struct SidebarView: View {
    @Environment(DownloadManager.self) private var manager
    @Binding var filter: SidebarFilter?

    private let library: [SidebarFilter] = [.all, .downloading, .queued, .paused, .completed]
    private let categories = Category.allCases.filter { $0 != .other }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Library").padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
                    ForEach(library, id: \.self) { item in
                        row(item) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(filter == item ? Theme.accent : Theme.textSecondary)
                                .frame(width: 22)
                        }
                    }
                    SectionLabel("Categories").padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
                    ForEach(categories) { category in
                        row(.category(category)) {
                            CategoryTile(category: category, size: 22, cornerRadius: 6, symbolSize: 11)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
            // Like a sidebar list: one focus stop, arrow keys move the selection.
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(by: -1) }
            .onKeyPress(.downArrow) { move(by: 1) }
            SpeedLimitCard()
                .padding(10)
        }
        // Room for the window controls and the sidebar toggle, which sit on the panel.
        .padding(.top, 44)
        .glassPanel(cornerRadius: 16, fill: Theme.glass)
        .padding([.leading, .top, .bottom], 8)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowBackdrop().ignoresSafeArea())
    }

    private var allFilters: [SidebarFilter] { library + categories.map { .category($0) } }

    private func move(by offset: Int) -> KeyPress.Result {
        let filters = allFilters
        let index = filters.firstIndex { $0 == filter } ?? 0
        filter = filters[min(max(index + offset, 0), filters.count - 1)]
        return .handled
    }

    private func row(_ item: SidebarFilter, @ViewBuilder icon: () -> some View) -> some View {
        let selected = filter == item
        return Button { filter = item } label: {
            HStack(spacing: 10) {
                icon()
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(manager.count(for: item))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
