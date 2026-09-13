import UIKit
import WebKit
import UserNotifications
import MapKit
import CoreLocation
import Speech
import AVFoundation

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var placeCache: [String: [String: Any]] = [:]
    private let geoLock = NSLock()

    // Γλώσσα ΕΜΦΑΝΙΣΗΣ των αποτελεσμάτων = γλώσσα εφαρμογής (όπως uiLocale() στο Android).
    // Δεν έχει σχέση με τη γλώσσα του μικροφώνου, που ακολουθεί τη συσκευή.
    private var uiLangCode = "el"
    private func uiLocale() -> Locale {
        uiLangCode.lowercased().hasPrefix("en") ? Locale(identifier: "en_US") : Locale(identifier: "el_GR")
    }
    // Όριο Ελλάδας: ίδιο bbox με το Android (34.80–41.80 / 19.30–28.25) ως κύκλος για τον CLGeocoder.
    private func greeceRegion() -> CLCircularRegion {
        CLCircularRegion(center: CLLocationCoordinate2D(latitude: 38.30, longitude: 23.78), radius: 480_000, identifier: "greece")
    }
    private func inGreeceBox(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude >= 34.80 && c.latitude <= 41.80 && c.longitude >= 19.30 && c.longitude <= 28.25
    }

    // Η Apple «μαντεύει» όταν δεν ξέρει το μέρος: «Σχολεία Γκράβα» -> «Σμόλικα, Γέρακας».
    // Η Google του Honor δεν το κάνει. Κρατάμε μόνο αποτελέσματα που περιέχουν έστω μία
    // λέξη από αυτό που γράφτηκε (όνομα/οδός/περιοχή, ελληνικά ή λατινικά)· αλλιώς
    // πετιούνται και το JS συνεχίζει σε OSM ή κρατά το κείμενο αυτούσιο.
    private static let geoStopWords: Set<String> = [
        "ellada", "elladas", "greece", "hellas", "hotel", "xenodocheio", "athina", "athinas", "athens",
        "attiki", "attica", "kai", "and", "the", "odos", "street", "leoforos", "avenue", "plateia", "square"
    ]
    private func geoLatin(_ s: String) -> String {
        let t = s.applyingTransform(.toLatin, reverse: false) ?? s
        return (t.applyingTransform(.stripDiacritics, reverse: false) ?? t).lowercased()
    }
    private func geoGreek(_ s: String) -> String {
        (s.applyingTransform(.stripDiacritics, reverse: false) ?? s).lowercased()
    }
    private func geoStem(_ s: String) -> String {
        // «Γκράβας» ~ «Γκράβα», «Πειραιάς» ~ «Πειραιά»
        (s.hasSuffix("s") || s.hasSuffix("ς")) ? String(s.dropLast()) : s
    }
    private func geoTokens(_ q: String) -> [String] {
        let cleaned = q.replacingOccurrences(of: #"[^\p{L}\s]"#, with: " ", options: .regularExpression)
        return cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { t in
            t.count >= 3 && !Self.geoStopWords.contains(geoLatin(t))
        }
    }
    private func placemarkBlob(_ p: CLPlacemark, name: String?) -> String {
        [name, p.name, p.thoroughfare, p.subLocality, p.locality, p.subAdministrativeArea,
         p.administrativeArea, (p.areasOfInterest ?? []).joined(separator: " ")]
            .compactMap { $0 }.joined(separator: " ")
    }
    private func hitMatchesQuery(_ q: String, _ p: CLPlacemark, name: String?) -> Bool {
        // Λιμάνι/πύλη/αεροδρόμιο: το JS τα εμπιστεύεται όπως είναι (όπως στο Honor).
        if q.range(of: #"λιμ|port|gate|πυλη|πύλη|αεροδρ|airport"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let toks = geoTokens(q)
        if toks.isEmpty { return true }
        let blob = placemarkBlob(p, name: name)
        let bl = geoLatin(blob), bg = geoGreek(blob)
        for t in toks {
            let l = geoStem(geoLatin(t)), g = geoStem(geoGreek(t))
            if (l.count >= 3 && bl.contains(l)) || (g.count >= 3 && bg.contains(g)) { return true }
        }
        return false
    }

    // Φωνή → κείμενο (ίδιο «συμβόλαιο» με το Android: __onAppSpeechPartial / __onAppSpeechResult)
    private var speechRecognizer: SFSpeechRecognizer?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private let speechEngine = AVAudioEngine()
    private var speechSilenceTimer: Timer?
    private var speechMaxTimer: Timer?
    private var speechBestText = ""
    private var speechBestAlts: [String] = []
    private var speechDelivered = false
    private var speechSession = 0

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
        case "startSpeechToText":
            startSpeechToText(langCode: str(args, 0))
        case "stopSpeechToText":
            stopSpeechToText()
        case "setUiLang":
            let c = str(args, 0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !c.isEmpty { uiLangCode = c; VpsPush.setLang(c) }
        case "geocodeAddress":
            geocodeAddress(query: str(args, 0), requestId: str(args, 1))
        case "reverseGeocode":
            reverseGeocode(lat: str(args, 0), lon: str(args, 1), requestId: str(args, 2))
        case "placeAutocomplete":
            placeAutocomplete(query: str(args, 0), requestId: str(args, 1))
        case "placeDetails":
            placeDetails(placeId: str(args, 0), requestId: str(args, 1))
        case "lockPageScroll":
            webView.scrollView.isScrollEnabled = false
        case "unlockPageScroll":
            webView.scrollView.isScrollEnabled = true
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
            return "[]"
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

    // Η Apple δίνει ως «περιοχή» το διοικητικό «Δημοτική Κοινότητα 3ης Περιστερίου» —
    // η Google του Honor δίνει τη γειτονιά. Το διοικητικό δεν είναι διεύθυνση: πετιέται.
    private func cleanSuburb(_ s: String?) -> String {
        let v = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if v.range(of: #"^(\d+η\s+)?(Δημοτικ[ήη]\s+(Κοινότητα|Ενότητα)|Δ\.\s?[ΚΕ]\.|Municipal\s+(Unit|Community)|Community\s+of)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil { return "" }
        return v
    }

    // Ίδια μορφή με το getAddressLine(0) της Google: «Οδός Αρ., Περιοχή ΤΚ»
    private func displayLine(road: String, number: String, area: String, city: String, postcode: String) -> String {
        let street = [road, number].filter { !$0.isEmpty }.joined(separator: " ")
        let place = [area.isEmpty ? city : area, postcode].filter { !$0.isEmpty }.joined(separator: " ")
        return [street, place].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func placemarkDict(_ p: CLPlacemark, name: String?) -> [String: Any] {
        let c = p.location?.coordinate
        let lat = c?.latitude ?? 0
        let lon = c?.longitude ?? 0
        let road = p.thoroughfare ?? ""
        let number = p.subThoroughfare ?? ""
        let suburb = cleanSuburb(p.subLocality)
        let city = p.locality ?? p.subAdministrativeArea ?? ""
        var postcode = p.postalCode ?? ""
        if postcode.isEmpty, let m = (p.name ?? "").range(of: #"\b\d{3} ?\d{2}\b"#, options: .regularExpression) {
            postcode = String((p.name ?? "")[m])
        }
        let display = displayLine(road: road, number: number, area: suburb, city: city, postcode: postcode)
        return [
            "lat": lat,
            "lon": lon,
            "display_name": display.isEmpty ? (name ?? p.name ?? "") : display,
            "name": name ?? p.name ?? "",
            "road": road,
            "house_number": number,
            "city": city,
            "suburb": suburb,
            "postcode": postcode
        ]
    }

    // ΤΚ/γειτονιά που λείπουν από την Apple: συμπλήρωση από το OSM, native (το WebView
    // δεν φτάνει πάντα στο nominatim). Ένα αίτημα ανά μετακίνηση πινέζας, 5s timeout.
    private func nominatimReverse(lat: Double, lon: Double, done: @escaping ([String: String]) -> Void) {
        let langQ = uiLangCode.hasPrefix("en") ? "en" : "el"
        guard let url = URL(string: "https://nominatim.openstreetmap.org/reverse?lat=\(lat)&lon=\(lon)&format=jsonv2&addressdetails=1&zoom=18&accept-language=\(langQ)") else {
            done([:]); return
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("TaxiAndFlyClient/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var out: [String: String] = [:]
            if let data = data,
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let a = j["address"] as? [String: Any] {
                func f(_ keys: [String]) -> String {
                    for k in keys { if let v = a[k] as? String, !v.isEmpty { return v } }
                    return ""
                }
                out["road"] = f(["road", "pedestrian", "footway", "path"])
                out["house_number"] = f(["house_number"])
                out["suburb"] = f(["suburb", "neighbourhood", "quarter"])
                out["city"] = f(["city", "town", "village", "municipality"])
                out["postcode"] = f(["postcode"])
            }
            done(out)
        }.resume()
    }

    /// Ίδια λίστα δοκιμών με το Android `geocodeAddressJson` (MainActivity.kt): πύλη Ε{n},
    /// «και» → «&», το query, παραλλαγές Πειραιά/λιμανιού, «, Ελλάδα», «hotel, Ελλάδα».
    /// Σταματά στην πρώτη δοκιμή που δίνει αποτέλεσμα. Γεωκωδικοποίηση από την Apple
    /// (δωρεάν, όπως ο Geocoder του τηλεφώνου στο Android), στη γλώσσα της εφαρμογής.
    private func geocodeTries(for query: String) -> [String] {
        var tries: [String] = []
        let low = query.lowercased()
        if let gate = query.range(of: #"(?:gate|πύλη|πυλη)\s*[eε]?\s*(\d{1,2})"#, options: [.regularExpression, .caseInsensitive]) {
            let n = String(query[gate]).replacingOccurrences(of: #"[^\d]"#, with: "", options: .regularExpression)
            if !n.isEmpty {
                tries.append("Πύλη Ε\(n) Πειραιάς")
                tries.append("Piraeus Port Gate E\(n)")
                tries.append("Gate E\(n) Piraeus")
            }
        }
        let kai = #"\s+(και|kai)\s+"#
        if query.range(of: kai, options: [.regularExpression, .caseInsensitive]) != nil {
            tries.append(query.replacingOccurrences(of: kai, with: " & ", options: [.regularExpression, .caseInsensitive]))
        }
        tries.append(query)
        let piraeus = query.range(of: #"pir[aeiouy]+e?us|pireas|piraus|πειραι"#, options: [.regularExpression, .caseInsensitive]) != nil
        let port = low.contains("λιμάν") || low.contains("λιμαν") || low.contains("port") || low.contains("harbour") || low.contains("harbor")
        // Τα γενικά «Piraeus Port»/«Λιμάνι Πειραιά» ΤΕΛΕΥΤΑΙΑ (fallback), όπως στο Android.
        if piraeus && port {
            tries.append("Piraeus Port")
            tries.append("Λιμάνι Πειραιά")
        } else if piraeus {
            tries.append("Piraeus Port")
            tries.append("Piraeus")
        } else if port {
            tries.append("\(query) λιμάνι")
            tries.append("Piraeus Port")
        }
        if !low.contains("ελλάδα") && !low.contains("ellada") && !low.contains("greece") {
            tries.append("\(query), Ελλάδα")
        }
        let hasDigit = query.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        if !hasDigit && !low.contains("hotel") && !low.contains("ξενοδοχ") {
            tries.append("\(query) hotel, Ελλάδα")
        }
        return tries
    }

    private func geocodeAddress(query: String, requestId: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count < 2 {
            nativeCallback("__onNativeGeocode", id: requestId, payload: "[]")
            return
        }
        geocodeTryList(geocodeTries(for: q), original: q, requestId: requestId, index: 0)
    }

    private func geocodeTryList(_ tries: [String], original: String, requestId: String, index: Int) {
        if index >= tries.count {
            // Καμία δοκιμή δεν βρήκε διεύθυνση: τελευταία ευκαιρία το POI search της Apple
            // (ξενοδοχεία, λιμάνι, σταθμοί), που ο CLGeocoder δεν ξέρει με το όνομά τους.
            geocodePoiFallback(original, requestId: requestId)
            return
        }
        let tryQ = tries[index]
        let locale = uiLocale()
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(tryQ, in: greeceRegion(), preferredLocale: locale) { [weak self] marks, _ in
            _ = geocoder // κρατιέται ζωντανός μέχρι την απάντηση
            guard let self = self else { return }
            var out: [[String: Any]] = []
            var seen = Set<String>()
            for m in marks ?? [] {
                guard let c = m.location?.coordinate else { continue }
                guard m.isoCountryCode == nil || m.isoCountryCode == "GR" else { continue }
                guard self.inGreeceBox(c) else { continue }
                guard self.hitMatchesQuery(tryQ, m, name: m.name) else {
                    NSLog("geocoder try=\"%@\" dropped unrelated \"%@\"", tryQ, self.placemarkBlob(m, name: m.name))
                    continue
                }
                let key = String(format: "%.5f,%.5f", c.latitude, c.longitude)
                if !seen.insert(key).inserted { continue }
                out.append(self.placemarkDict(m, name: m.name))
                if out.count >= 8 { break }
            }
            NSLog("geocoder try=\"%@\" -> %d", tryQ, out.count)
            if !out.isEmpty {
                self.nativeCallback("__onNativeGeocode", id: requestId, payload: self.jsonPayload(out))
                return
            }
            self.geocodeTryList(tries, original: original, requestId: requestId, index: index + 1)
        }
    }

    private func geocodePoiFallback(_ query: String, requestId: String) {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 38.30, longitude: 23.78),
            span: MKCoordinateSpan(latitudeDelta: 7.0, longitudeDelta: 9.0)
        )
        req.resultTypes = [.pointOfInterest, .address]
        MKLocalSearch(request: req).start { [weak self] resp, _ in
            guard let self = self else { return }
            var out: [[String: Any]] = []
            var seen = Set<String>()
            for item in resp?.mapItems ?? [] {
                guard let c = item.placemark.location?.coordinate, self.inGreeceBox(c) else { continue }
                guard self.hitMatchesQuery(query, item.placemark, name: item.name) else { continue }
                let key = String(format: "%.5f,%.5f", c.latitude, c.longitude)
                if !seen.insert(key).inserted { continue }
                var d = self.placemarkDict(item.placemark, name: item.name)
                d["type"] = item.pointOfInterestCategory == .hotel ? "hotel" : "address"
                out.append(d)
                if out.count >= 8 { break }
            }
            NSLog("geocoder poi-fallback=\"%@\" -> %d", query, out.count)
            self.nativeCallback("__onNativeGeocode", id: requestId, payload: self.jsonPayload(out))
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
        geocoder.reverseGeocodeLocation(loc, preferredLocale: uiLocale()) { [weak self] marks, _ in
            _ = geocoder
            guard let self = self else { return }
            var arr = (marks ?? []).prefix(5).map { self.placemarkDict($0, name: $0.name) }
            func str(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? "" }
            let first = arr.first ?? [:]
            let complete = !arr.isEmpty && !str(first, "postcode").isEmpty && !str(first, "suburb").isEmpty && !str(first, "road").isEmpty
            if complete {
                self.nativeCallback("__onNativeReverse", id: requestId, payload: self.jsonPayload(arr))
                return
            }
            self.nominatimReverse(lat: la, lon: lo) { n in
                var d = arr.first ?? ["lat": la, "lon": lo, "name": ""]
                for k in ["road", "house_number", "suburb", "city", "postcode"] where str(d, k).isEmpty {
                    if let v = n[k], !v.isEmpty { d[k] = v }
                }
                let line = self.displayLine(road: str(d, "road"), number: str(d, "house_number"),
                                            area: str(d, "suburb"), city: str(d, "city"), postcode: str(d, "postcode"))
                if !line.isEmpty { d["display_name"] = line }
                if arr.isEmpty { if !line.isEmpty { arr = [d] } } else { arr[0] = d }
                NSLog("reverse %@ -> %@", "\(la),\(lo)", line)
                self.nativeCallback("__onNativeReverse", id: requestId, payload: self.jsonPayload(arr))
            }
        }
    }

    private func placeAutocomplete(query: String, requestId: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count < 2 {
            nativeCallback("__onNativePlaces", id: requestId, payload: "[]")
            return
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = atticaRegion()
        req.resultTypes = [.pointOfInterest, .address]
        MKLocalSearch(request: req).start { [weak self] resp, _ in
            guard let self = self else { return }
            var out: [[String: Any]] = []
            self.geoLock.lock()
            defer { self.geoLock.unlock() }
            for item in resp?.mapItems ?? [] {
                let id = "ios-" + UUID().uuidString
                var d = self.placemarkDict(item.placemark, name: item.name)
                d["place_id"] = id
                let hotel = item.pointOfInterestCategory == .hotel
                d["type"] = hotel ? "hotel" : "address"
                d["class"] = hotel ? "tourism" : "place"
                d["types"] = hotel ? ["lodging"] : []
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
        if let cached {
            nativeCallback("__onNativePlaceDetails", id: requestId, payload: jsonPayload(cached))
        } else {
            nativeCallback("__onNativePlaceDetails", id: requestId, payload: "null")
        }
    }

    // MARK: - Φωνή → κείμενο (μικρόφωνο στο πεδίο διεύθυνσης και στο chat)

    private func speechLocale(_ code: String) -> Locale {
        let l = code.lowercased()
        if l.hasPrefix("en") { return Locale(identifier: "en-US") }
        if l.hasPrefix("el") { return Locale(identifier: "el-GR") }
        // "auto": η γλώσσα της συσκευής (όπως στο Android)
        return Locale.current
    }

    private func startSpeechToText(langCode: String) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized else {
                self.speechResultToJs(text: "", error: "permission", alts: [])
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard granted else {
                        self.speechResultToJs(text: "", error: "permission", alts: [])
                        return
                    }
                    self.beginSpeech(langCode: langCode)
                }
            }
        }
    }

    private func stopSpeechToText() {
        endSpeechAudio()
    }

    private func beginSpeech(langCode: String) {
        stopSpeechInternal()
        speechSession += 1
        let sid = speechSession
        var rec = SFSpeechRecognizer(locale: speechLocale(langCode))
        if rec == nil || !(rec!.isAvailable) {
            rec = SFSpeechRecognizer(locale: Locale(identifier: "el-GR"))
        }
        guard let recognizer = rec, recognizer.isAvailable else {
            speechResultToJs(text: "", error: "unavailable", alts: [])
            return
        }
        speechRecognizer = recognizer
        speechBestText = ""
        speechBestAlts = []
        speechDelivered = false

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            speechResultToJs(text: "", error: "error", alts: [])
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        speechRequest = request

        let input = speechEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        speechEngine.prepare()
        do {
            try speechEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            speechResultToJs(text: "", error: "error", alts: [])
            return
        }

        speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, sid == self.speechSession else { return }
                if let result = result {
                    let alts = result.transcriptions
                        .map { $0.formattedString.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.speechBestText = text
                        self.speechBestAlts = alts
                    }
                    if result.isFinal {
                        self.finishSpeech(error: self.speechBestText.isEmpty ? "no_match" : "")
                        return
                    }
                    if !text.isEmpty { self.speechPartialToJs(text: text, alts: alts) }
                    self.restartSpeechSilenceTimer()
                }
                if error != nil {
                    // Σφάλμα ή «δεν άκουσα τίποτα»: παραδίδουμε ό,τι καλύτερο ακούστηκε, αλλιώς no_match.
                    self.finishSpeech(error: self.speechBestText.isEmpty ? "no_match" : "")
                }
            }
        }

        restartSpeechSilenceTimer()
        speechMaxTimer?.invalidate()
        speechMaxTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            self?.endSpeechAudio()
        }
    }

    /// Όπως στο Android: μόλις σταματήσεις να μιλάς, το μικρόφωνο κλείνει μόνο του.
    private func restartSpeechSilenceTimer() {
        speechSilenceTimer?.invalidate()
        let interval: TimeInterval = speechBestText.isEmpty ? 5.0 : 1.6
        speechSilenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.endSpeechAudio()
        }
    }

    /// Κλείνει το μικρόφωνο· το τελικό αποτέλεσμα έρχεται από το recognitionTask (isFinal).
    private func endSpeechAudio() {
        guard speechRequest != nil else { return }
        speechSilenceTimer?.invalidate()
        speechSilenceTimer = nil
        if speechEngine.isRunning {
            speechEngine.stop()
            speechEngine.inputNode.removeTap(onBus: 0)
        }
        speechRequest?.endAudio()
        let sid = speechSession
        // Αν το isFinal αργήσει, παραδίδουμε ό,τι έχουμε.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, sid == self.speechSession, !self.speechDelivered else { return }
            self.finishSpeech(error: self.speechBestText.isEmpty ? "no_match" : "")
        }
    }

    private func finishSpeech(error: String) {
        if speechDelivered { return }
        speechDelivered = true
        let text = speechBestText
        let alts = speechBestAlts
        stopSpeechInternal()
        speechResultToJs(text: error.isEmpty ? text : "", error: error, alts: error.isEmpty ? alts : [])
    }

    private func stopSpeechInternal() {
        speechSilenceTimer?.invalidate()
        speechSilenceTimer = nil
        speechMaxTimer?.invalidate()
        speechMaxTimer = nil
        if speechEngine.isRunning {
            speechEngine.stop()
            speechEngine.inputNode.removeTap(onBus: 0)
        }
        speechRequest?.endAudio()
        speechTask?.cancel()
        speechTask = nil
        speechRequest = nil
        _ = try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func speechResultToJs(text: String, error: String, alts: [String]) {
        let js = "try{if(window.__onAppSpeechResult)window.__onAppSpeechResult(\(jsString(text)),\(jsString(error)),\(jsonPayload(alts)));}catch(e){}"
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func speechPartialToJs(text: String, alts: [String]) {
        let js = "try{if(window.__onAppSpeechPartial)window.__onAppSpeechPartial(\(jsString(text)),\(jsonPayload(alts)));}catch(e){}"
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
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
        stopSpeechToText: function(){ call('stopSpeechToText',[]); },
        setUiLang: function(l){ call('setUiLang',[l]); },
        geocodeAddress: function(q,id){ call('geocodeAddress',[q,id]); },
        reverseGeocode: function(lat,lon,id){ call('reverseGeocode',[lat,lon,id]); },
        placeAutocomplete: function(q,id){ call('placeAutocomplete',[q,id]); },
        placeDetails: function(id,req){ call('placeDetails',[id,req]); },
        lockPageScroll: function(){ call('lockPageScroll',[]); },
        unlockPageScroll: function(){ call('unlockPageScroll',[]); }
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
