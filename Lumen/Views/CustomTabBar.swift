import SwiftUI

struct TabBarItem {
    let icon: String
    let filledIcon: String
    let title: String
}

/// Replaces the native `TabView`/`tabItem` chrome with something on-brand — a sliding pink
/// pill behind the selected icon instead of default iOS tint, matching the pink/rounded
/// language used everywhere else in the app (ProfileCardView, filter pills, etc).
struct CustomTabBar: View {
    @Binding var selectedTab: Int
    let items: [TabBarItem]
    @Namespace private var indicatorNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let isSelected = selectedTab == index

                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selectedTab = index
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            if isSelected {
                                Circle()
                                    .fill(Color.pink.opacity(0.14))
                                    .frame(width: 40, height: 40)
                                    .matchedGeometryEffect(id: "tabIndicator", in: indicatorNamespace)
                            }
                            Image(systemName: isSelected ? item.filledIcon : item.icon)
                                .font(.system(size: 20))
                                .foregroundStyle(isSelected ? Color.pink : Color.secondary)
                        }
                        .frame(width: 40, height: 40)

                        Text(item.title)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.pink : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(alignment: .top) {
            Color.lumenCard
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.06), radius: 12, y: -4)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.lumenDivider.opacity(0.6))
                        .frame(height: 0.5)
                }
        }
    }
}
