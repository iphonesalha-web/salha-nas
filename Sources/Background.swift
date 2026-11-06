import Foundation
import BackgroundTasks
import UserNotifications
import UIKit

/// النسخ الليلي: يشغّله الآيفون وهو مقفل على الشاحن والواي فاي.
enum NightlyBackup {
    static let id = "com.salha.nas.nightly"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            handle(task)
        }
    }

    static func schedule() {
        let r = BGProcessingTaskRequest(identifier: id)
        r.requiresExternalPower = true
        r.requiresNetworkConnectivity = true
        r.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
        try? BGTaskScheduler.shared.submit(r)
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule()
        task.expirationHandler = {
            Task { @MainActor in BackupEngine.shared.cancel() }
        }
        Task { @MainActor in
            let r = await BackupEngine.shared.run()
            if r.uploaded > 0 || r.failed > 0 {
                Notifier.post(title: "صالحة NAS", body: r.message)
            }
            task.setTaskCompleted(success: r.failed == 0)
        }
    }
}

/// تبدأ النسخ ثم تقفل الشاشة فيكمل، مع شريط تقدّم على شاشة القفل (iOS 26 وأحدث).
enum ForegroundBackup {
    @MainActor
    static func start() {
        if #available(iOS 26.0, *) {
            if startContinued() { return }
        }
        // الإصدارات الأقدم: نطلب وقتاً إضافياً قصيراً بعد الخروج من التطبيق
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "backup") {
            Task { @MainActor in BackupEngine.shared.cancel() }
            UIApplication.shared.endBackgroundTask(bg)
        }
        Task { @MainActor in
            await BackupEngine.shared.run()
            UIApplication.shared.endBackgroundTask(bg)
        }
    }

    @available(iOS 26.0, *)
    @MainActor
    private static func startContinued() -> Bool {
        let id = "com.salha.nas.continued." + UUID().uuidString
        let title = "نسخ الصور إلى NAS"

        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false); return
            }
            task.expirationHandler = {
                Task { @MainActor in BackupEngine.shared.cancel() }
            }
            Task { @MainActor in
                let engine = BackupEngine.shared
                var lastDone = -1
                engine.onProgress = { units, totalUnits, done, total in
                    task.progress.totalUnitCount = totalUnits
                    task.progress.completedUnitCount = units
                    if done != lastDone {
                        lastDone = done
                        task.updateTitle(title, subtitle: "\(done) من \(total)")
                    }
                }
                let r = await engine.run()
                engine.onProgress = nil
                task.updateTitle(title, subtitle: r.message)
                task.setTaskCompleted(success: r.failed == 0)
            }
        }
        guard registered else { return false }

        let req = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: "جاري التحضير…")
        req.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(req)
            return true
        } catch {
            return false
        }
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
