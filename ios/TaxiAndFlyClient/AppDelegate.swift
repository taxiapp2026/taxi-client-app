import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                DispatchQueue.main.async { application.registerForRemoteNotifications() }
            }
        }
        application.registerForRemoteNotifications()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        VpsPush.setApnsToken(deviceToken)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        VpsPush.startBackgroundPoll()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        VpsPush.pauseBackgroundPoll()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Immediate local notifies still call willPresent even after Home.
        // [] = only Notification Center, no banner. Show the pop unless the user is inside the app.
        if UIApplication.shared.applicationState == .active {
            completionHandler([])
            return
        }
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    // ✅ 14/10 — Πάτημα σε ειδοποίηση chat → ανοίγει κατευθείαν η συνομιλία της κράτησης.
    // Ο server βάζει type/bookingId στη ρίζα του APNs payload. Όλες οι άλλες ειδοποιήσεις: όπως πριν
    // (απλώς ανοίγει η εφαρμογή).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let type = (info["type"] as? String) ?? ""
        let bookingId = (info["bookingId"] as? String) ?? ""
        if type == "chat", !bookingId.isEmpty,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { [weak self] in
                (self?.window?.rootViewController as? ViewController)?.openChatFromNotification(bookingId)
            }
        }
        completionHandler()
    }
}
