import SwiftUI
import SwiftData

/// 根导航（对应 Android 单 Activity + Compose Navigation）
struct RootView: View {
    @State private var tab: Tab = .bookshelf

    enum Tab: Hashable { case bookshelf, settings }

    var body: some View {
        TabView(selection: $tab) {
            BookshelfView()
                .tabItem { Label("我的书架", systemImage: "books.vertical") }
                .tag(Tab.bookshelf)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}
