import UIKit
import WebKit
import UserNotifications

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
        loadClient()
    }

    override var prefersStatusBarHidden: Bool { true }

    private func setupWebView() {
        let content = WKUserContentController()
        content.add(self, name: "ClientBridge")
        content.addUserScript(WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 14.0, *) {
            config.limitsNavigationsToAppBoundDomains = false
        }
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let wv = WKWebView(frame: view.bounds, configuration: config)
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.scrollView.keyboardDismissMode = .interactive
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.bounces = false
        wv.scrollView.delaysContentTouches = false
        wv.scrollView.canCancelContentTouches = false
        wv.isOpaque = false
        wv.backgroundColor = .black
        view.addSubview(wv)
        webView = wv
        VpsPush.webView = wv
    }

    private func loadClient() {
        guard let www = Bundle.main.resourceURL?.appendingPathComponent("www") else { return }
        let index = www.appendingPathComponent("client.html")
        webView.loadFileURL(index, allowingReadAccessTo: www)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ClientBridge" else { return }
        let body = message.body as? [String: Any]
        let method = (body?["method"] as? String) ?? ""
        let args = (body?["args"] as? [Any]) ?? []
        handleBridge(method: method, args: args)
    }

    private func handleBridge(method: String, args: [Any]) {
        switch method {
        case "openPhone":
            openURL("tel:\(sanitizePhone(str(args, 0)))")
        case "openSMS":
            openURL("sms:\(sanitizePhone(str(args, 0)))")
        case "openWhatsApp":
            let digits = sanitizePhone(str(args, 0)).replacingOccurrences(of: "+", with: "")
            if !digits.isEmpty { openURL("https://wa.me/\(digits)") }
        case "openEmail":
            openURL("mailto:\(str(args, 0).trimmingCharacters(in: .whitespacesAndNewlines))")
        case "showKeyboard":
            webView.becomeFirstResponder()
        case "showLocalNotification":
            guard UIApplication.shared.applicationState != .active else { return }
            DispatchQueue.main.async {
                VpsPush.localNotify(title: self.str(args, 0), body: self.str(args, 1), id: "local_\(Int(Date().timeIntervalSince1970))")
            }
        case "markBookingSeen":
            VpsPush.markSeen(bookingId: str(args, 0), status: str(args, 1))
        case "cancelNotification":
            UNCenter.remove(id: str(args, 0))
        case "cancelDriverArrivedNotification", "cancelAllNotifications":
            UNCenter.removeAll()
        case "cancelClientUnconfirmedCheck":
            UNCenter.removeAll()
            VpsPush.stopWatch()
        case "scheduleClientUnconfirmedCheck", "watchBookingForNotifications":
            VpsPush.watchBooking(str(args, 0), webView: webView)
        case "sendChatNotification":
            VpsPush.sendChat(token: str(args, 0), title: str(args, 1), body: str(args, 2))
        case "getFcmToken":
            VpsPush.webView = webView
            VpsPush.deliverPushTokenToJs()
        case "log":
            NSLog("JS: %@", str(args, 0))
        case "startSpeechToText", "stopSpeechToText":
            break
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["tel", "sms", "mailto"].contains(scheme) || url.host == "wa.me" || (url.host ?? "").contains("whatsapp") {
            openURL(url.absoluteString)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            openURL(url.absoluteString)
        }
        return nil
    }

    private func openURL(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private func notify(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func str(_ args: [Any], _ i: Int) -> String {
        guard i < args.count else { return "" }
        return String(describing: args[i])
    }

    private func sanitizePhone(_ phone: String) -> String {
        String(phone.enumerated().compactMap { idx, ch in
            if ch.isNumber || (ch == "+" && idx == 0) { return ch }
            return nil
        })
    }

    private static let bridgeScript = """
    (function(){
      function call(name, args){
        try{ window.webkit.messageHandlers.ClientBridge.postMessage({method:name, args:args||[]}); }catch(e){}
      }
      var b = {
        openPhone: function(p){ call('openPhone',[p]); },
        openSMS: function(p){ call('openSMS',[p]); },
        openWhatsApp: function(p){ call('openWhatsApp',[p]); },
        openEmail: function(a){ call('openEmail',[a]); },
        showKeyboard: function(){ call('showKeyboard',[]); },
        cancelNotification: function(id){ call('cancelNotification',[id]); },
        cancelDriverArrivedNotification: function(){ call('cancelDriverArrivedNotification',[]); },
        cancelAllNotifications: function(){ call('cancelAllNotifications',[]); },
        showLocalNotification: function(t,b){ call('showLocalNotification',[t,b]); },
        markBookingSeen: function(id,st){ call('markBookingSeen',[id,st]); },
        scheduleClientUnconfirmedCheck: function(id,d,t){ call('scheduleClientUnconfirmedCheck',[id,d,t]); },
        watchBookingForNotifications: function(id){ call('watchBookingForNotifications',[id]); },
        cancelClientUnconfirmedCheck: function(){ call('cancelClientUnconfirmedCheck',[]); },
        getApiUrl: function(){ return '\(AppConfig.apiUrl)'; },
        getFcmToken: function(){ call('getFcmToken',[]); return null; },
        sendChatNotification: function(token,title,body){ call('sendChatNotification',[token,title,body]); },
        isAuthReady: function(){ return true; },
        log: function(m){ call('log',[m]); },
        startSpeechToText: function(lang){ call('startSpeechToText',[lang]); },
        stopSpeechToText: function(){ call('stopSpeechToText',[]); }
      };
      window.ClientBridge = b;
      window.AndroidBridge = b;
    })();
    """
}

private enum UNCenter {
    static func remove(id: String) {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: [id])
        c.removeDeliveredNotifications(withIdentifiers: [id])
    }
    static func removeAll() {
        let c = UNUserNotificationCenter.current()
        c.removeAllPendingNotificationRequests()
        c.removeAllDeliveredNotifications()
    }
}
