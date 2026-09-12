import Foundation

/// Local notification strings in the language the client chose in-app (not OS language).
enum NotifI18n {
    static let pack: [String: [String: (String, String)]] = [
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
        ]
    ]

    static func pair(lang: String, kind: String) -> (String, String) {
        let l = pack[lang] != nil ? lang : "el"
        return pack[l]?[kind] ?? pack["el"]!["arrived"]!
    }

    static func fromStatus(_ status: String, lang: String) -> (String, String)? {
        let kind: String?
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accepted", "booked", "confirmed": kind = "accepted"
        case "offered": kind = "offered"
        case "interested": kind = "interested"
        case "driver_ready", "arrived", "driverwaiting", "driver_waiting": kind = "arrived"
        case "cancelled", "canceled", "driver_cancelled": kind = "cancelled"
        case "cannot_find", "driver_cannot_find": kind = "cannot_find"
        case "chat", "message": kind = "chat"
        default: kind = nil
        }
        guard let kind else { return nil }
        return pair(lang: lang, kind: kind)
    }
}
