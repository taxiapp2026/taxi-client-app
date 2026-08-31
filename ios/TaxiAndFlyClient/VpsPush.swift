import Foundation
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
        DispatchQueue.main.async {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { _ in poll() }
            RunLoop.main.add(timer!, forMode: .common)
            poll()
        }
    }

    static func stopWatch() {
        DispatchQueue.main.async {
            timer?.invalidate()
            timer = nil
        }
        watchedId = nil
        lastKey = ""
    }

    static func localNotify(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
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
        localNotify(title: pair.0, body: pair.1, id: "booking_\(id)_\(st)")
        let jsSt = st.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let jsId = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.main.async {
            webView?.evaluateJavaScript(
                "if(typeof window.__iosNotifyBooking==='function'){window.__iosNotifyBooking(\"\(jsSt)\",\"\(jsId)\");}",
                completionHandler: nil
            )
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
