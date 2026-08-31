import Foundation
import UIKit
import UserNotifications
import WebKit

enum VpsPush {
    static weak var webView: WKWebView?
    private static var watchedId: String?
    private static var lastKey = ""
    private static var timer: Timer?
    private static var apnsToken = ""

    static func sendChat(token: String, title: String, body: String) {
        guard let url = URL(string: "\(AppConfig.apiUrl)/api/push/chat") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 25
        let payload: [String: String] = ["token": token, "title": title, "body": body]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }

    static func setApnsToken(_ data: Data) {
        apnsToken = data.map { String(format: "%02.2hhx", $0) }.joined()
        injectApns()
        registerApnsWithVps()
    }

    static func deliverPushTokenToJs() {
        injectApns()
    }

    static func watchBooking(_ bookingId: String, webView: WKWebView?) {
        let id = bookingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        self.webView = webView
        if watchedId != id {
            watchedId = id
            lastKey = ""
        }
        // Do not poll while the app is open — JS already listens live.
        // Polling /rtdb/bookings every 6s starved in-app chat and status.
    }

    static func startBackgroundPoll() {
        guard watchedId != nil else { return }
        DispatchQueue.main.async {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in poll() }
            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
            poll()
            var bgTask = UIBackgroundTaskIdentifier.invalid
            bgTask = UIApplication.shared.beginBackgroundTask {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }
    }

    static func pauseBackgroundPoll() {
        DispatchQueue.main.async {
            timer?.invalidate()
            timer = nil
        }
    }

    static func stopWatch() {
        pauseBackgroundPoll()
        watchedId = nil
        lastKey = ""
    }

    static func markSeen(bookingId: String, status: String) {
        let id = bookingId.trimmingCharacters(in: .whitespacesAndNewlines)
        let st = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty, !st.isEmpty else { return }
        if watchedId == nil { watchedId = id }
        lastKey = "\(id):\(st)"
    }

    static func localNotify(title: String, body: String, id: String) {
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .active
            }
            // nil trigger is treated as in-app: iOS puts it in Notification Center without a banner.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
            let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            center.add(req, withCompletionHandler: { err in
                if let err {
                    NSLog("TaxiAndFly notify error: %@", err.localizedDescription)
                }
            })
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted {
                        DispatchQueue.main.async {
                            UIApplication.shared.registerForRemoteNotifications()
                            deliver()
                        }
                    }
                }
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { deliver() }
            default:
                DispatchQueue.main.async { deliver() }
            }
        }
    }

    private static func injectApns() {
        guard !apnsToken.isEmpty else { return }
        let escaped = apnsToken.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let js = "if(typeof window.__onClientApnsToken==='function'){window.__onClientApnsToken(\"\(escaped)\");}"
        DispatchQueue.main.async { webView?.evaluateJavaScript(js, completionHandler: nil) }
    }

    private static func registerApnsWithVps() {
        guard !apnsToken.isEmpty, let url = URL(string: "\(AppConfig.apiUrl)/api/push/register") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 20
        let payload: [String: String] = [
            "platform": "ios",
            "token": apnsToken,
            "bundleId": AppConfig.bundleId
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }

    private static func poll() {
        guard let id = watchedId, let url = URL(string: "\(AppConfig.apiUrl)/rtdb/bookings/\(id)") else { return }
        var req = URLRequest(url: url)
        req.setValue(AppConfig.apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            handleBooking(id, obj)
        }.resume()
    }

    private static func handleBooking(_ id: String, _ b: [String: Any]) {
        var st = String(b["status"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if (b["showDriverReady"] as? Bool == true) || (b["driverConfirmedOk"] as? Bool == true) {
            st = "driver_ready"
        }
        if b["driverCannotFindClient"] as? Bool == true {
            st = "driver_cannot_find"
        }
        let key = "\(id):\(st)"
        guard key != lastKey else { return }
        let notifyStatuses: Set<String> = [
            "accepted", "booked", "confirmed", "offered", "interested",
            "driver_ready", "arrived", "cancelled", "canceled", "driver_cancelled", "driver_cannot_find"
        ]
        guard notifyStatuses.contains(st) else { return }
        lastKey = key
        let pair = message(for: st)
        DispatchQueue.main.async {
            localNotify(title: pair.0, body: pair.1, id: "booking_\(id)_\(st)")
        }
    }

    private static func message(for st: String) -> (String, String) {
        switch st {
        case "accepted", "booked", "confirmed":
            return ("Booking accepted", "A driver accepted your booking.")
        case "offered":
            return ("Price confirmation", "The driver sent a price. Open the app.")
        case "interested":
            return ("Driver found", "A driver is interested. Please wait.")
        case "driver_ready", "arrived":
            return ("Driver arrived", "Your driver is at the pickup point.")
        case "driver_cannot_find":
            return ("Driver could not find you", "Open the app to explain.")
        default:
            return ("Booking update", "Open Taxi and Fly for details.")
        }
    }
}
