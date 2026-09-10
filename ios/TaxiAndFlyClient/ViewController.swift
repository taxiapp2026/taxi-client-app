import UIKit
import WebKit
import UserNotifications
import MapKit
import CoreLocation

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var placeCache: [String: [String: Any]] = [:]
    private let geoLock = NSLock()

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
            notify(title: str(args, 0), body: str(args, 1), id: "local_obs")
        case "cancelNotification":
            UNCenter.remove(id: str(args, 0))
        case "cancelDriverArrivedNotification", "cancelAllNotifications", "cancelClientUnconfirmedCheck":
            UNCenter.removeAll()
        case "scheduleClientUnconfirmedCheck", "watchBookingForNotifications":
            break
        case "sendChatNotification":
            VpsPush.sendChat(token: str(args, 0), title: str(args, 1), body: str(args, 2))
        case "getFcmToken":
            break
        case "log":
            NSLog("JS: %@", str(args, 0))
        case "startSpeechToText", "stopSpeechToText":
            break
        case "geocodeAddress":
            geocodeAddress(query: str(args, 0), requestId: str(args, 1))
        case "reverseGeocode":
            reverseGeocode(lat: str(args, 0), lon: str(args, 1), requestId: str(args, 2))
        case "placeAutocomplete":
            placeAutocomplete(query: str(args, 0), requestId: str(args, 1))
        case "placeDetails":
            placeDetails(placeId: str(args, 0), requestId: str(args, 1))
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

    private func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("\"\"".utf8)
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    private func jsonPayload(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return (obj is NSNull) ? "null" : "[]"
        }
        return s
    }

    private func nativeCallback(_ fn: String, id: String, payload: String) {
        let idJs = jsString(id)
        let js = "if(typeof window.\(fn)==='function'){window.\(fn)(\(idJs), \(payload));}"
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func atticaRegion() -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72),
            span: MKCoordinateSpan(latitudeDelta: 2.6, longitudeDelta: 2.6)
        )
    }

    private func gateNumber(_ query: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "(?:gate|πύλη|πυλη)\\s*[eε]?\\s*(\\d{1,2})", options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        guard let m = re.firstMatch(in: query, options: [], range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: query) else { return nil }
        return String(query[r])
    }

    private func placemarkDict(_ p: CLPlacemark, name: String?) -> [String: Any] {
        let c = p.location?.coordinate
        let lat = c?.latitude ?? 0
        let lon = c?.longitude ?? 0
        let display = [
            [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.joined(separator: " "),
            p.subLocality ?? p.locality ?? "",
            p.postalCode ?? ""
        ].filter { !$0.isEmpty }.joined(separator: ", ")
        var postcode = p.postalCode ?? ""
        if postcode.isEmpty, let m = display.range(of: #"\b\d{5}\b"#, options: .regularExpression) {
            postcode = String(display[m])
        }
        return [
            "lat": lat,
            "lon": lon,
            "display_name": display.isEmpty ? (name ?? p.name ?? "") : display,
            "name": name ?? p.name ?? "",
            "road": p.thoroughfare ?? "",
            "house_number": p.subThoroughfare ?? "",
            "city": p.locality ?? "",
            "suburb": p.subLocality ?? "",
            "postcode": postcode
        ]
    }

    private func mapItemDict(_ item: MKMapItem, id: String) -> [String: Any] {
        let p = item.placemark
        var d = placemarkDict(p, name: item.name)
        let hotel = item.pointOfInterestCategory == .hotel
        d["place_id"] = id
        d["subtitle"] = [p.thoroughfare, p.locality, p.postalCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        d["type"] = hotel ? "hotel" : "address"
        d["class"] = hotel ? "tourism" : "place"
        return d
    }

    private func geocodeAddress(query: String, requestId: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count < 2 {
            nativeCallback("__onNativeGeocode", id: requestId, payload: "[]")
            return
        }
        var tries: [String] = []
        if let n = gateNumber(q) {
            tries.append("Πύλη Ε\(n) Πειραιάς")
            tries.append("Piraeus Port Gate E\(n)")
            tries.append("Gate E\(n) Piraeus")
        }
        tries.append(q)
        if !q.lowercased().contains("ελλάδα") && !q.lowercased().contains("greece") {
            tries.append("\(q), Ελλάδα")
        }
        geocodeNext(tries: tries, index: 0, requestId: requestId)
    }

    private func geocodeNext(tries: [String], index: Int, requestId: String) {
        if index >= tries.count {
            nativeCallback("__onNativeGeocode", id: requestId, payload: "[]")
            return
        }
        let geocoder = CLGeocoder()
        let locale = Locale(identifier: "el_GR")
        geocoder.geocodeAddressString(tries[index], in: nil, preferredLocale: locale) { [weak self] marks, _ in
            guard let self = self else { return }
            let good = (marks ?? []).filter { $0.location != nil && ($0.isoCountryCode == "GR" || $0.isoCountryCode == nil) }
            if !good.isEmpty {
                let arr = good.prefix(8).map { self.placemarkDict($0, name: $0.name) }
                self.nativeCallback("__onNativeGeocode", id: requestId, payload: self.jsonPayload(arr))
                return
            }
            self.geocodeNext(tries: tries, index: index + 1, requestId: requestId)
        }
    }

    private func reverseGeocode(lat: String, lon: String, requestId: String) {
        guard let la = Double(lat.replacingOccurrences(of: ",", with: ".")),
              let lo = Double(lon.replacingOccurrences(of: ",", with: ".")) else {
            nativeCallback("__onNativeReverse", id: requestId, payload: "[]")
            return
        }
        let geocoder = CLGeocoder()
        let loc = CLLocation(latitude: la, longitude: lo)
        geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "el_GR")) { [weak self] marks, _ in
            guard let self = self else { return }
            let arr = (marks ?? []).prefix(5).map { self.placemarkDict($0, name: $0.name) }
            self.nativeCallback("__onNativeReverse", id: requestId, payload: self.jsonPayload(arr))
        }
    }

    private func placeAutocomplete(query: String, requestId: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count < 2 {
            nativeCallback("__onNativePlaces", id: requestId, payload: "[]")
            return
        }
        var searchQuery = q
        if let n = gateNumber(q) {
            searchQuery = "Πύλη Ε\(n) Πειραιάς"
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = searchQuery
        req.region = atticaRegion()
        req.resultTypes = [.pointOfInterest, .address]
        MKLocalSearch(request: req).start { [weak self] resp, _ in
            guard let self = self else { return }
            var out: [[String: Any]] = []
            self.geoLock.lock()
            defer { self.geoLock.unlock() }
            for item in resp?.mapItems ?? [] {
                let id = "ios-" + UUID().uuidString
                let d = self.mapItemDict(item, id: id)
                self.placeCache[id] = d
                out.append(d)
                if out.count >= 8 { break }
            }
            self.nativeCallback("__onNativePlaces", id: requestId, payload: self.jsonPayload(out))
        }
    }

    private func placeDetails(placeId: String, requestId: String) {
        geoLock.lock()
        let cached = placeCache[placeId]
        geoLock.unlock()
        if let cached = cached {
            nativeCallback("__onNativePlaceDetails", id: requestId, payload: jsonPayload(cached))
        } else {
            nativeCallback("__onNativePlaceDetails", id: requestId, payload: "null")
        }
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
        scheduleClientUnconfirmedCheck: function(id,d,t){ call('scheduleClientUnconfirmedCheck',[id,d,t]); },
        watchBookingForNotifications: function(id){ call('watchBookingForNotifications',[id]); },
        cancelClientUnconfirmedCheck: function(){ call('cancelClientUnconfirmedCheck',[]); },
        getApiUrl: function(){ return '\(AppConfig.apiUrl)'; },
        getFcmToken: function(){ call('getFcmToken',[]); return null; },
        sendChatNotification: function(token,title,body){ call('sendChatNotification',[token,title,body]); },
        isAuthReady: function(){ return true; },
        log: function(m){ call('log',[m]); },
        startSpeechToText: function(lang){ call('startSpeechToText',[lang]); },
        stopSpeechToText: function(){ call('stopSpeechToText',[]); },
        geocodeAddress: function(q,id){ call('geocodeAddress',[q,id]); },
        reverseGeocode: function(lat,lon,id){ call('reverseGeocode',[lat,lon,id]); },
        placeAutocomplete: function(q,id){ call('placeAutocomplete',[q,id]); },
        placeDetails: function(pid,id){ call('placeDetails',[pid,id]); }
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
