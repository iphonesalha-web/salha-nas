import AppIntents

/// يظهر في تطبيق الاختصارات حتى تعمل أتمتة «عند توصيل الشاحن».
struct StartBackupIntent: AppIntent {
    static var title: LocalizedStringResource = "نسخ الصور إلى NAS"
    static var description = IntentDescription("ينسخ الصور والفيديوهات الجديدة إلى قرص الـ FRITZ!Box.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NightlyBackup.schedule()
        let r = await BackupEngine.shared.run()
        return .result(dialog: IntentDialog(stringLiteral: r.message))
    }
}

struct SalhaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartBackupIntent(),
            phrases: ["انسخ الصور في \(.applicationName)", "Backup photos with \(.applicationName)"],
            shortTitle: "نسخ الصور",
            systemImageName: "externaldrive.badge.icloud"
        )
    }
}
