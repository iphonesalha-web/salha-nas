import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NightlyBackup.register()
        NightlyBackup.schedule()
        return true
    }
}

@main
struct SalhaNASApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(BackupEngine.shared)
                .environment(\.layoutDirection, .rightToLeft)
                .tint(Color(red: 0.16, green: 0.62, blue: 0.56))
        }
        .onChange(of: phase) { p in
            if p == .background { NightlyBackup.schedule() }
        }
    }
}
