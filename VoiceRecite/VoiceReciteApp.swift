import SwiftUI

@main
struct VoiceReciteApp: App {
    init() {
        // 告诉应用市场：我装了，版本是 x.y
        StoreHandshake.report()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { StoreHandshake.report() }
        }
    }
}
