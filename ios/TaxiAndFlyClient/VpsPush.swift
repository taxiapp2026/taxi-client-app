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
    /// Γλώσσα ΚΙΝΗΤΟΥ (όχι εφαρμογής): έτσι διαβάζει ο πελάτης τις ειδοποιήσεις στην οθόνη
    /// κλειδώματος. Στέλνεται και στον server (/api/push/register) που έχει τον ίδιο πίνακα.
    static func setLang(_ code: String) { /* η γλώσσα εφαρμογής δεν επηρεάζει τις ειδοποιήσεις */ }
    static func lang() -> String {
        let pref = (Locale.preferredLanguages.first ?? "en").lowercased()
        let c = String(pref.split(separator: "-").first ?? "en")
        return pack[c] != nil ? c : "en"
    }
    static func text(_ kind: String) -> (String, String) {
        let l = lang()
        return pack[l]?[kind] ?? pack["el"]?[kind] ?? ("Taxi and Fly", "")
    }

    // Ίδιος πίνακας με το ClientNotifI18n.kt του Honor (γλώσσα εφαρμογής, όχι OS).
    private static let pack: [String: [String: (String, String)]] = [
        "el": [
            "accepted": ("Η κράτηση έγινε δεκτή", "Ένας οδηγός αποδέχτηκε την κράτηση."),
            "offered": ("Επιβεβαίωση τιμής", "Ο οδηγός έστειλε τιμή. Άνοιξε την εφαρμογή για αποδοχή."),
            "interested": ("Βρέθηκε οδηγός", "Ένας οδηγός ενδιαφέρεται. Περίμενε λίγο."),
            "arrived": ("Ο οδηγός έφτασε", "Ο οδηγός είναι στο σημείο παραλαβής."),
            "cancelled": ("Η κράτηση ακυρώθηκε", "Άνοιξε την εφαρμογή για λεπτομέρειες."),
            "cannot_find": ("🚫 Ο οδηγός δεν σας βρήκε", "Ο οδηγός δεν μπόρεσε να σας βρει. Παρακαλούμε εξηγήστε γιατί δεν απαντήσατε."),
            "chat": ("Νέο μήνυμα", "Ο οδηγός έστειλε μήνυμα.")
        ],
        "en": [
            "accepted": ("Booking accepted", "A driver accepted your booking."),
            "offered": ("Price confirmation", "The driver sent a price. Open the app to accept."),
            "interested": ("Driver found", "A driver is interested. Please wait."),
            "arrived": ("Driver arrived", "Your driver is at the pickup point."),
            "cancelled": ("Booking cancelled", "Open the app for details."),
            "cannot_find": ("🚫 Driver could not find you", "The driver could not find you. Please explain why you did not answer."),
            "chat": ("New message", "The driver sent a message.")
        ],
        "de": [
            "accepted": ("Buchung angenommen", "Ein Fahrer hat Ihre Buchung angenommen."),
            "offered": ("Preisbestätigung", "Der Fahrer hat einen Preis gesendet. Öffnen Sie die App zum Annehmen."),
            "interested": ("Fahrer gefunden", "Ein Fahrer ist interessiert. Bitte warten."),
            "arrived": ("Fahrer ist da", "Ihr Fahrer ist am Abholpunkt."),
            "cancelled": ("Buchung storniert", "Öffnen Sie die App für Details."),
            "cannot_find": ("🚫 Fahrer hat Sie nicht gefunden", "Der Fahrer konnte Sie nicht finden. Bitte erklären Sie, warum Sie nicht geantwortet haben."),
            "chat": ("Neue Nachricht", "Der Fahrer hat eine Nachricht gesendet.")
        ],
        "fr": [
            "accepted": ("Réservation acceptée", "Un chauffeur a accepté votre réservation."),
            "offered": ("Confirmation du prix", "Le chauffeur a envoyé un prix. Ouvrez l'application pour accepter."),
            "interested": ("Chauffeur trouvé", "Un chauffeur est intéressé. Veuillez patienter."),
            "arrived": ("Le chauffeur est arrivé", "Votre chauffeur est au point de prise en charge."),
            "cancelled": ("Réservation annulée", "Ouvrez l'application pour les détails."),
            "cannot_find": ("🚫 Le chauffeur ne vous a pas trouvé", "Le chauffeur n'a pas pu vous trouver. Veuillez expliquer pourquoi vous n'avez pas répondu."),
            "chat": ("Nouveau message", "Le chauffeur a envoyé un message.")
        ],
        "it": [
            "accepted": ("Prenotazione accettata", "Un autista ha accettato la tua prenotazione."),
            "offered": ("Conferma prezzo", "L'autista ha inviato un prezzo. Apri l'app per accettare."),
            "interested": ("Autista trovato", "Un autista è interessato. Attendi."),
            "arrived": ("L'autista è arrivato", "Il tuo autista è al punto di partenza."),
            "cancelled": ("Prenotazione annullata", "Apri l'app per i dettagli."),
            "cannot_find": ("🚫 L'autista non ti ha trovato", "L'autista non è riuscito a trovarti. Spiega perché non hai risposto."),
            "chat": ("Nuovo messaggio", "L'autista ha inviato un messaggio.")
        ],
        "es": [
            "accepted": ("Reserva aceptada", "Un conductor ha aceptado tu reserva."),
            "offered": ("Confirmación de precio", "El conductor envió un precio. Abre la app para aceptar."),
            "interested": ("Conductor encontrado", "Un conductor está interesado. Espera."),
            "arrived": ("El conductor ha llegado", "Tu conductor está en el punto de recogida."),
            "cancelled": ("Reserva cancelada", "Abre la app para ver los detalles."),
            "cannot_find": ("🚫 El conductor no te encontró", "El conductor no pudo encontrarte. Explica por qué no respondiste."),
            "chat": ("Mensaje nuevo", "El conductor ha enviado un mensaje.")
        ],
        "ru": [
            "accepted": ("Заказ принят", "Водитель принял ваш заказ."),
            "offered": ("Подтверждение цены", "Водитель отправил цену. Откройте приложение, чтобы принять."),
            "interested": ("Водитель найден", "Водитель заинтересован. Подождите."),
            "arrived": ("Водитель прибыл", "Водитель на месте подачи."),
            "cancelled": ("Заказ отменён", "Откройте приложение для подробностей."),
            "cannot_find": ("🚫 Водитель вас не нашёл", "Водитель не смог вас найти. Пожалуйста, объясните, почему вы не ответили."),
            "chat": ("Новое сообщение", "Водитель отправил сообщение.")
        ],
        "pl": [
            "accepted": ("Rezerwacja przyjęta", "Kierowca przyjął Twoją rezerwację."),
            "offered": ("Potwierdzenie ceny", "Kierowca wysłał cenę. Otwórz aplikację, aby zaakceptować."),
            "interested": ("Znaleziono kierowcę", "Kierowca jest zainteresowany. Czekaj."),
            "arrived": ("Kierowca przyjechał", "Twój kierowca jest w miejscu odbioru."),
            "cancelled": ("Rezerwacja anulowana", "Otwórz aplikację, aby zobaczyć szczegóły."),
            "cannot_find": ("🚫 Kierowca Cię nie znalazł", "Kierowca nie mógł Cię znaleźć. Wyjaśnij, dlaczego nie odpowiedziałeś."),
            "chat": ("Nowa wiadomość", "Kierowca wysłał wiadomość.")
        ],
        "tr": [
            "accepted": ("Rezervasyon kabul edildi", "Bir sürücü rezervasyonunuzu kabul etti."),
            "offered": ("Fiyat onayı", "Sürücü bir fiyat gönderdi. Kabul etmek için uygulamayı açın."),
            "interested": ("Sürücü bulundu", "Bir sürücü ilgileniyor. Lütfen bekleyin."),
            "arrived": ("Sürücü geldi", "Sürücünüz alınış noktasında."),
            "cancelled": ("Rezervasyon iptal edildi", "Ayrıntılar için uygulamayı açın."),
            "cannot_find": ("🚫 Sürücü sizi bulamadı", "Sürücü sizi bulamadı. Lütfen neden cevap vermediğinizi açıklayın."),
            "chat": ("Yeni mesaj", "Sürücü bir mesaj gönderdi.")
        ],
        "ar": [
            "accepted": ("تم قبول الحجز", "قبل سائق حجزك."),
            "offered": ("تأكيد السعر", "أرسل السائق سعراً. افتح التطبيق للقبول."),
            "interested": ("تم العثور على سائق", "سائق مهتم. يرجى الانتظار."),
            "arrived": ("وصل السائق", "السائق عند نقطة الانطلاق."),
            "cancelled": ("تم إلغاء الحجز", "افتح التطبيق للتفاصيل."),
            "cannot_find": ("🚫 لم يجدك السائق", "لم يتمكن السائق من العثور عليك. يرجى توضيح سبب عدم الرد."),
            "chat": ("رسالة جديدة", "أرسل السائق رسالة.")
        ],
        "zh": [
            "accepted": ("预订已接受", "司机已接受您的预订。"),
            "offered": ("价格确认", "司机发送了价格。请打开应用接受。"),
            "interested": ("已找到司机", "有司机感兴趣。请稍候。"),
            "arrived": ("司机已到达", "司机已在上车点。"),
            "cancelled": ("预订已取消", "请打开应用查看详情。"),
            "cannot_find": ("🚫 司机未找到您", "司机未能找到您。请说明您为何没有回应。"),
            "chat": ("新消息", "司机发来一条消息。")
        ],
        "ro": [
            "accepted": ("Rezervare acceptată", "Un șofer a acceptat rezervarea."),
            "offered": ("Confirmare preț", "Șoferul a trimis un preț. Deschide aplicația pentru a accepta."),
            "interested": ("Șofer găsit", "Un șofer este interesat. Te rugăm așteaptă."),
            "arrived": ("Șoferul a ajuns", "Șoferul este la punctul de preluare."),
            "cancelled": ("Rezervare anulată", "Deschide aplicația pentru detalii."),
            "cannot_find": ("🚫 Șoferul nu te-a găsit", "Șoferul nu te-a putut găsi. Te rugăm să explici de ce nu ai răspuns."),
            "chat": ("Mesaj nou", "Șoferul a trimis un mesaj.")
        ],
        "nl": [
            "accepted": ("Boeking geaccepteerd", "Een chauffeur heeft uw boeking geaccepteerd."),
            "offered": ("Prijsbevestiging", "De chauffeur stuurde een prijs. Open de app om te accepteren."),
            "interested": ("Chauffeur gevonden", "Een chauffeur is geïnteresseerd. Even geduld."),
            "arrived": ("Chauffeur gearriveerd", "Uw chauffeur is bij het ophaalpunt."),
            "cancelled": ("Boeking geannuleerd", "Open de app voor details."),
            "cannot_find": ("🚫 Chauffeur kon u niet vinden", "De chauffeur kon u niet vinden. Leg uit waarom u niet reageerde."),
            "chat": ("Nieuw bericht", "De chauffeur stuurde een bericht.")
        ],
        "uk": [
            "accepted": ("Бронювання прийнято", "Водій прийняв ваше бронювання."),
            "offered": ("Підтвердження ціни", "Водій надіслав ціну. Відкрийте додаток, щоб прийняти."),
            "interested": ("Водія знайдено", "Водій зацікавлений. Зачекайте."),
            "arrived": ("Водій прибув", "Водій на місці подачі."),
            "cancelled": ("Бронювання скасовано", "Відкрийте додаток для деталей."),
            "cannot_find": ("🚫 Водій вас не знайшов", "Водій не зміг вас знайти. Поясніть, чому ви не відповіли."),
            "chat": ("Нове повідомлення", "Водій надіслав повідомлення.")
        ],
        "he": [
            "accepted": ("ההזמנה התקבלה", "נהג קיבל את ההזמנה שלכם."),
            "offered": ("אישור מחיר", "הנהג שלח מחיר. פתחו את האפליקציה לאישור."),
            "interested": ("נמצא נהג", "נהג מעוניין. אנא המתינו."),
            "arrived": ("הנהג הגיע", "הנהג בנקודת האיסוף."),
            "cancelled": ("ההזמנה בוטלה", "פתחו את האפליקציה לפרטים."),
            "cannot_find": ("🚫 הנהג לא מצא אתכם", "הנהג לא הצליח למצוא אתכם. אנא הסבירו מדוע לא עניתם."),
            "chat": ("הודעה חדשה", "הנהג שלח הודעה.")
        ],
    ]

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

    /// Ο server (οδηγός) στέλνει το ίδιο γεγονός και μέσω APNs, στα ελληνικά. Όταν το app
    /// βγάζει τη δική του μεταφρασμένη ειδοποίηση, σβήνει το πρόσφατο push του server —
    /// τώρα και ξανά λίγο μετά, αν το push φτάσει δεύτερο.
    private static func removeRecentRemotePushes(within seconds: TimeInterval) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { list in
            let now = Date()
            let ids = list.filter { n in
                (n.request.trigger is UNPushNotificationTrigger) && now.timeIntervalSince(n.date) < seconds
            }.map { $0.request.identifier }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    static func localNotify(title: String, body: String, id: String) {
        let center = UNUserNotificationCenter.current()
        removeRecentRemotePushes(within: 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { removeRecentRemotePushes(within: 12) }
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
            "bundleId": AppConfig.bundleId,
            "lang": lang()   // ο server μεταφράζει τα push (έφτασε/chat/ακύρωση) σε αυτή τη γλώσσα
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
        // «Έφτασε», ακύρωση/no-show και «δεν σας βρήκε» τα στέλνει ήδη ο οδηγός μέσω APNs
        // (και το JS όσο ζει) — το poll δεν τα ξαναβγάζει. Μένουν όσα δεν στέλνει κανείς.
        let kind: String
        switch st {
        case "accepted", "booked", "confirmed": kind = "accepted"
        case "offered": kind = "offered"
        case "interested": kind = "interested"
        default: return
        }
        lastKey = key
        let pair = text(kind)
        DispatchQueue.main.async {
            localNotify(title: pair.0, body: pair.1, id: "booking_\(id)_\(st)")
        }
    }
}
