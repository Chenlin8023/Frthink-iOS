import SwiftUI
import SwiftData

@main
struct FrthinkApp: App {
    let container: ModelContainer

    @AppStorage("appearance.mode") private var appearanceMode: String = "system"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            container = try ModelContainer(
                for: BookProject.self, ChatMessage.self, CharacterCard.self,
                WorldEntry.self, CorpusEntry.self, WritingRule.self,
                PlotEvent.self, BodySnapshot.self, UsageRecord.self,
                migrationPlan: nil
            )
        } catch {
            fatalError("SwiftData 初始化失败: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(colorScheme)
                .environment(\.modelContext, container.mainContext)
        }
        .modelContainer(container)
    }

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
