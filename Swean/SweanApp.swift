import SwiftUI

@main
struct SweanApp: App {
    @State private var library = PhotoLibrary()
    @State private var store = ReviewStore()
    @State private var seriesStore = SeriesStore()
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(store)
                .environment(seriesStore)
                .preferredColorScheme(appearance.colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: library.refreshStatus()
            case .background, .inactive: store.saveNow()
            @unknown default: break
            }
        }
    }
}
