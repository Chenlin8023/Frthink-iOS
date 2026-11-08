import SwiftUI
import SwiftData

/// 根导航（对应 Android 单 Activity + Compose Navigation）
/// 书架为根页，设置从书架右上角齿轮进入——避免与工作台 TabView 形成双层底部标签栏
struct RootView: View {
    var body: some View {
        NavigationStack {
            BookshelfView()
        }
    }
}
