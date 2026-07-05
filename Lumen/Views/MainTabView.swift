import SwiftUI
import Combine

/// Lets a pushed detail screen (currently just `ChatView`) hide the custom tab bar for its
/// duration. The tab bar is a manual `.safeAreaInset` here, not a native `TabView`/tabItem, so it
/// never got UIKit's automatic "hide tab bar when a screen is pushed" behavior — without this,
/// the tab bar stayed reserved at the bottom of the screen even while chatting, and the chat's
/// own message-input bar (which sits above it) had no room left to actually render.
final class TabBarVisibility: ObservableObject {
    static let shared = TabBarVisibility()
    @Published var isHidden = false
}

struct MainTabView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @StateObject private var tabBarVisibility = TabBarVisibility.shared
    @State private var selectedTab = 0
    /// Tracks which tabs have been visited at least once — a tab's view isn't created at all
    /// until then. Native `TabView` only instantiates the selected tab's content up front;
    /// mounting all four eagerly here made every tab's `.task` data-load fire concurrently at
    /// launch (regardless of which tab was actually visible), which was racing with each other
    /// and showing up as spurious cancelled-request errors. Once visited, a tab stays mounted
    /// (just hidden via opacity) so its scroll position/loaded state survives switching away —
    /// but that means `.task` alone would only ever fire once per tab per app session, never
    /// refreshing on a later revisit (e.g. a new match made while on Discover never showing up
    /// on Matches without a manual pull-to-refresh). Likes You and Matches take `isActive` and
    /// reload on every transition back to true; Discovery deliberately doesn't (reloading its
    /// swipe stack every revisit would reset/reshuffle your position mid-swipe, worse than the
    /// staleness it'd fix).
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
                LikesYouView(isActive: selectedTab == 1)
                    .opacity(selectedTab == 1 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 1)
            }
            if visitedTabs.contains(2) {
                MatchListView(isActive: selectedTab == 2)
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
            if !tabBarVisibility.isHidden {
                CustomTabBar(selectedTab: $selectedTab, items: items)
            }
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
