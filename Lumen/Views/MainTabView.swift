import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var selectedTab = 0
    /// Tracks which tabs have been visited at least once — a tab's view isn't created at all
    /// until then. Native `TabView` only instantiates the selected tab's content up front;
    /// mounting all four eagerly here made every tab's `.task` data-load fire concurrently at
    /// launch (regardless of which tab was actually visible), which was racing with each other
    /// and showing up as spurious cancelled-request errors. Once visited, a tab stays mounted
    /// (just hidden via opacity) so its scroll position/loaded state survives switching away.
    @State private var visitedTabs: Set<Int> = [0]

    private let items: [TabBarItem] = [
        TabBarItem(icon: "flame", filledIcon: "flame.fill", title: "Discover"),
        // Likes You — free for everyone, no paywall (app_spec.md Section 3.3)
        TabBarItem(icon: "star", filledIcon: "star.fill", title: "Likes You"),
        TabBarItem(icon: "heart", filledIcon: "heart.fill", title: "Matches"),
        TabBarItem(icon: "person", filledIcon: "person.fill", title: "Profile"),
    ]

    var body: some View {
        ZStack {
            if visitedTabs.contains(0) {
                DiscoveryView()
                    .opacity(selectedTab == 0 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 0)
            }
            if visitedTabs.contains(1) {
                LikesYouView()
                    .opacity(selectedTab == 1 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 1)
            }
            if visitedTabs.contains(2) {
                MatchListView()
                    .opacity(selectedTab == 2 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 2)
            }
            if visitedTabs.contains(3) {
                ProfileView()
                    .opacity(selectedTab == 3 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 3)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CustomTabBar(selectedTab: $selectedTab, items: items)
        }
        .onChange(of: selectedTab) { _, newValue in
            visitedTabs.insert(newValue)
        }
        .tint(.pink)
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthenticationManager.shared)
}
