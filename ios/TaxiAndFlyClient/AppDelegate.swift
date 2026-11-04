import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Self.installDownSound()
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
            // «Μαζί» (2/11): οι ειδοποιήσεις της παρέας (από τον server) φαίνονται και με την εφαρμογή ανοιχτή,
            // όπως στο Android. Όλες οι άλλες: όπως πριν (μόνο στο Κέντρο ειδοποιήσεων).
            if Self.isMaziPush(notification) {
                if #available(iOS 14.0, *) {
                    completionHandler([.banner, .list, .sound])
                } else {
                    completionHandler([.alert, .sound])
                }
                return
            }
            // «Το ταξί έφτασε και σας περιμένει κάτω»: ο ήχος παίζει και με ανοιχτή εφαρμογή (το μόνιτορ δείχνει ήδη το μήνυμα).
            if (notification.request.content.userInfo["loud"] as? String) == "1" {
                completionHandler([.sound])
                return
            }
            completionHandler([])
            return
        }
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    /// 4/11: το iOS ψάχνει τον ήχο του push στο Library/Sounds. Το αρχείο έρχεται μέσα στο www/sounds της εφαρμογής.
    private static func installDownSound() {
        let fm = FileManager.default
        guard let srcDir = Bundle.main.resourceURL?.appendingPathComponent("www/sounds"),
              let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first,
              let files = try? fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil) else { return }
        let dir = lib.appendingPathComponent("Sounds", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for src in files where src.pathExtension == "caf" {
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    /// Push του server για «Μαζί»: type "mazi_…", κράτηση-θέση «<κράτηση>#mN» (π.χ. «Ο οδηγός έφτασε» στον συνεπιβάτη)
    /// ή σημάδι mazi="1" (το «Ο οδηγός είναι κάτω» του μισθωτή, που φεύγει από την κανονική ροή).
    private static func isMaziPush(_ n: UNNotification) -> Bool {
        guard n.request.trigger is UNPushNotificationTrigger else { return false }
        return isMaziPayload(n.request.content.userInfo)
    }

    static func isMaziPayload(_ info: [AnyHashable: Any]) -> Bool {
        let type = (info["type"] as? String) ?? ""
        let bookingId = (info["bookingId"] as? String) ?? ""
        let mazi = (info["mazi"] as? String) ?? ""
        return type.hasPrefix("mazi_") || bookingId.contains("#m") || mazi == "1"
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
