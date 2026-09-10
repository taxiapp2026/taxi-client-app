package com.example.taxi
import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.view.inputmethod.InputMethodManager
import android.net.Uri
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import org.json.JSONObject
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebView
import android.webkit.WebViewClient
import android.location.Geocoder
import org.json.JSONArray
import kotlin.concurrent.thread
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.tasks.Tasks
import com.google.android.libraries.places.api.Places
import com.google.android.libraries.places.api.model.AutocompleteSessionToken
import com.google.android.libraries.places.api.model.Place
import com.google.android.libraries.places.api.model.RectangularBounds
import com.google.android.libraries.places.api.net.FetchPlaceRequest
import com.google.android.libraries.places.api.net.FindAutocompletePredictionsRequest
import com.google.android.libraries.places.api.net.PlacesClient
import java.util.concurrent.TimeUnit
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import com.example.taxi.BuildConfig
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.example.taxi.vps.*
import com.google.firebase.messaging.FirebaseMessaging
import java.text.SimpleDateFormat
import java.util.Locale

class MainActivity : AppCompatActivity() {

    override fun attachBaseContext(newBase: Context) {
        // Neutralize system "Font size" so the app looks the same on every phone
        val config = android.content.res.Configuration(newBase.resources.configuration)
        config.fontScale = 1.0f
        super.attachBaseContext(newBase.createConfigurationContext(config))
    }

    private lateinit var webView: WebView
    private var fcmToken: String? = null
    private var authReady: Boolean = false
    private val TAG = "ClientMainActivity"
    private val REQ_NOTIF = 1001
    private val REQ_RECORD_AUDIO = 1002
    private var speechRecognizer: android.speech.SpeechRecognizer? = null
    private var pendingSpeechLang: String = "el"
    private var placesClient: PlacesClient? = null
    private var placesToken: AutocompleteSessionToken? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var unconfirmedCheckRunnable: Runnable? = null
    private var activeBookingWatcher: ValueEventListener? = null
    private var activeBookingWatcherId: String? = null
    private val bookingWatcherLock = Any()
    private var bookingWatcherStartingId: String? = null
    private val vpsWatcherJsFiredKeys = mutableSetOf<String>()

    private fun clearVpsWatcherJsFiredKeys(bookingId: String? = null) {
        synchronized(vpsWatcherJsFiredKeys) {
            if (bookingId.isNullOrBlank()) {
                vpsWatcherJsFiredKeys.clear()
            } else {
                val prefix = "$bookingId:"
                vpsWatcherJsFiredKeys.removeAll { it.startsWith(prefix) }
            }
        }
    }

    private fun fireVpsWatcherJsOnce(bookingId: String, action: String, js: String) {
        val key = "$bookingId:$action"
        synchronized(vpsWatcherJsFiredKeys) {
            if (!vpsWatcherJsFiredKeys.add(key)) return
        }
        safeEval(js)
    }

    private var pageReady: Boolean = false
    private var pendingClientT200BookingId: String? = null
    private var pendingDriverCannotFindBookingId: String? = null
    private var pendingDriverReadyBookingId: String? = null
    private var lastTerminalRecoverAt: Long = 0L
    private var reloadAttempted: Boolean = false
    private var e2eAutoPrice: Boolean = false
    private var e2eUiFlow: Boolean = false

    private fun jsBookingId(bookingId: String): String =
        bookingId.replace("\\", "\\\\").replace("'", "\\'")

    private fun openClientT200ViaVps(bookingId: String) {
        if (bookingId.isBlank()) return
        val safeId = jsBookingId(bookingId)
        safeEval(
            "try{" +
                    "if(typeof window._clientTry200FromAndroid==='function'){" +
                    "window._clientTry200FromAndroid('$safeId');" +
                    "}else if(typeof window.openClientT200FromAndroid==='function'){" +
                    "window.openClientT200FromAndroid('$safeId');" +
                    "}" +
                    "}catch(e){}"
        )
    }

    private fun openDriverReadyViaVps(bookingId: String) {
        if (bookingId.isBlank()) return
        val safeId = jsBookingId(bookingId)
        safeEval(
            "try{" +
                    "if(typeof window.openDriverReadyFromAndroid==='function'){" +
                    "window.openDriverReadyFromAndroid('$safeId');" +
                    "}else if(typeof window.showDriverReadyOverlay==='function'){" +
                    "window._clientForcedMonitorBid='$safeId';window.__forceDriverReadyMonitorRender=true;" +
                    "var db=window._clientDb,fns=window._clientDbFns||{};" +
                    "if(db&&fns.get&&fns.ref){" +
                    "fns.get(fns.ref(db,'bookings/$safeId')).then(function(s){" +
                    "var b=s?s.val():null;if(b){window.showDriverReadyOverlay('$safeId',b);}" +
                    "});" +
                    "}else{setTimeout(function(){if(typeof window.showDriverReadyOverlay==='function'){var d=window._clientDb,f=window._clientDbFns||{};if(d&&f.get&&f.ref){f.get(f.ref(d,'bookings/$safeId')).then(function(s){var b=s?s.val():null;if(b)window.showDriverReadyOverlay('$safeId',b);});}}},600);}" +
                    "}" +
                    "}catch(e){}"
        )
    }

    private fun startClientVpsBookingWatch(bookingId: String) {
        startBookingWatcher(bookingId)
        Log.d(TAG, "VPS client booking watch for $bookingId")
    }

    private fun startBookingWatcher(bookingId: String) {
        if (bookingId.isBlank()) return
        synchronized(bookingWatcherLock) {
            if (activeBookingWatcherId == bookingId && activeBookingWatcher != null) return
            if (bookingWatcherStartingId == bookingId) return
            bookingWatcherStartingId = bookingId
            if (activeBookingWatcherId != bookingId) {
                clearVpsWatcherJsFiredKeys(activeBookingWatcherId)
                stopBookingWatcherLocked()
            }
            clearVpsWatcherJsFiredKeys(bookingId)
            activeBookingWatcherId = bookingId
        }
        runOnUiThread {
            synchronized(bookingWatcherLock) {
                try {
                    if (activeBookingWatcher != null && activeBookingWatcherId == bookingId) return@runOnUiThread

                    val ref = FirebaseDatabase.getInstance().getReference("bookings/$bookingId")
                    val listener = object : ValueEventListener {
                        override fun onDataChange(snapshot: DataSnapshot) {
                            if (!snapshot.exists()) return
                            val b = snapshot.getValue() as? Map<*, *> ?: return
                            val showStep3 = b["showClientUnconfirmedStep3"] as? Boolean == true
                            val driverConfirmedOk = b["driverConfirmedOk"] as? Boolean == true
                            val showDriverReady = b["showDriverReady"] as? Boolean == true
                            val clientSeenReady = b["clientSeenReady"] as? Boolean == true
                            val clientDeclinedRetry = b["clientDeclinedRetry"] as? Boolean == true
                            val clientAcknowledgedCancel = b["clientAcknowledgedCancel"] as? Boolean == true
                            val clientContactedDriver = b["clientContactedDriver"] as? Boolean == true
                            val clientRequestedNewDriver = b["clientRequestedNewDriver"] as? Boolean == true
                            val clientNeedsAitiologia = b["clientNeedsAitiologia"] as? Boolean == true
                            val driverCancelledCannotFind = b["driverCancelledCannotFind"] as? Boolean == true
                            val driverCannotFindClient = b["driverCannotFindClient"] as? Boolean == true
                            val clientAitiologiaSubmitted = b["clientAitiologiaSubmitted"] as? Boolean == true
                            val clientAitiologia = b["clientAitiologia"]
                            val safeId = jsBookingId(bookingId)

                            // T-2:00 — monitor μέσα στην εφαρμογή (showClientUnconfirmedStep3). Όχι push 2:15.
                            if (showStep3 && !driverConfirmedOk && !clientDeclinedRetry && !clientAcknowledgedCancel && !clientContactedDriver && !clientRequestedNewDriver && !clientNeedsAitiologia && !driverCancelledCannotFind && !clientAitiologiaSubmitted && clientAitiologia == null) {
                                Log.d(TAG, "VPS T-2:00 in-app trigger for $bookingId")
                                openClientT200ViaVps(bookingId)
                            }

                            if (driverCannotFindClient && !clientAitiologiaSubmitted && clientAitiologia == null) {
                                showClientLocalNotification(
                                    bookingId,
                                    "driver_cannot_find",
                                    "🚫 Ο Οδηγός Δεν Σας Βρήκε",
                                    "Ο οδηγός δεν μπόρεσε να σας βρει. Παρακαλούμε εξηγήστε γιατί δεν απαντήσατε.",
                                    "openDriverCannotFind"
                                )
                                safeEval(
                                    "try{" +
                                            "if(typeof window._showCannotFindOverlay==='function'){" +
                                            "window._showCannotFindOverlay('$safeId');" +
                                            "}" +
                                            "}catch(e){}"
                                )
                            }

                            if ((showDriverReady || driverConfirmedOk) && !clientSeenReady && !clientNeedsAitiologia && !driverCancelledCannotFind && !clientAitiologiaSubmitted && clientAitiologia == null) {
                                Log.d(TAG, "Driver ready for $bookingId — open overlay")
                                openDriverReadyViaVps(bookingId)
                            }

                            val driverWaiting = b["driverWaiting"] as? Boolean == true
                            if (!driverWaiting && !driverCancelledCannotFind) {
                                safeEval(
                                    "try{" +
                                            "if(typeof window._closeDriverWaitingMonitor==='function'){" +
                                            "window._closeDriverWaitingMonitor('$safeId');" +
                                            "}" +
                                            "}catch(e){}"
                                )
                            }
                        }

                        override fun onCancelled(error: DatabaseError) {
                            Log.e(TAG, "Booking watcher cancelled: ${error.message}")
                        }
                    }

                    ref.addValueEventListener(listener)
                    activeBookingWatcher = listener
                    Log.d(TAG, "✅ Firebase booking watcher started for $bookingId")
                } finally {
                    if (bookingWatcherStartingId == bookingId) bookingWatcherStartingId = null
                }
            }
        }
    }

    inner class AndroidBridge {
        @JavascriptInterface
        fun getFcmToken(): String? {
            val token = fcmToken
            if (token != null) {
                val escaped = token.replace("\\", "\\\\").replace("\"", "\\\"")
                safeEval("if(typeof window.__onClientFcmToken==='function'){window.__onClientFcmToken(\"$escaped\");}")
            }
            return token
        }

        @JavascriptInterface
        fun sendChatNotification(token: String, title: String, body: String) {
            VpsHttp.sendChatNotification(token, title, body)
        }

        @JavascriptInterface
        fun isAuthReady(): Boolean = authReady

        @JavascriptInterface
        fun showKeyboard() {
            runOnUiThread {
                try {
                    if (!::webView.isInitialized) return@runOnUiThread
                    webView.isFocusable = true
                    webView.isFocusableInTouchMode = true
                    webView.requestFocus()
                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                    imm?.showSoftInput(webView, InputMethodManager.SHOW_IMPLICIT)
                } catch (e: Exception) {
                    Log.e(TAG, "showKeyboard error: $e")
                }
            }
        }

        @JavascriptInterface
        fun openPhone(phone: String) {
            openExternalIntent(Intent.ACTION_DIAL, "tel:${sanitizePhone(phone)}")
        }

        @JavascriptInterface
        fun openSMS(phone: String) {
            openExternalIntent(Intent.ACTION_SENDTO, "smsto:${sanitizePhone(phone)}")
        }

        @JavascriptInterface
        fun openWhatsApp(phone: String) {
            val digits = sanitizePhone(phone).removePrefix("+")
            if (digits.isNotBlank()) {
                openExternalIntent(Intent.ACTION_VIEW, "https://wa.me/$digits")
            }
        }

        @JavascriptInterface
        fun openEmail(address: String) {
            openMailto(address.trim())
        }

        @JavascriptInterface
        fun showLocalNotification(title: String, body: String) {
            try {
                val channelId = "booking_reminder"
                val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                val notification = NotificationCompat.Builder(this@MainActivity, channelId)
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                    .setPriority(NotificationCompat.PRIORITY_MAX)
                    .setAutoCancel(true)
                    .setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
                    .setVibrate(longArrayOf(0, 400, 200, 400))
                    .build()
                manager.notify("local_obs", 0, notification)
            } catch (e: Exception) {
                Log.e(TAG, "showLocalNotification error: $e")
            }
        }

        @JavascriptInterface
        fun scheduleClientUnconfirmedCheck(bookingId: String, dateStr: String, timeStr: String) {
            this@MainActivity.startBookingWatcher(bookingId)
        }

        @JavascriptInterface
        fun watchBookingForNotifications(bookingId: String) {
            this@MainActivity.startBookingWatcher(bookingId)
        }

        @JavascriptInterface
        fun cancelClientUnconfirmedCheck() {
            unconfirmedCheckRunnable?.let { mainHandler.removeCallbacks(it) }
            unconfirmedCheckRunnable = null
            stopBookingWatcher()
            Log.d(TAG, "Booking watcher cancelled")
        }

        @JavascriptInterface
        fun getApiUrl(): String = VpsConfig.API_URL

        @JavascriptInterface
        fun log(msg: String?) {
            Log.d(TAG, "JS: ${msg ?: ""}")
        }

        @JavascriptInterface
        fun startSpeechToText(langCode: String) {
            val device = Locale.getDefault()
            val deviceLang = device.language.lowercase(Locale.ROOT)
            val deviceCountry = device.country.uppercase(Locale.ROOT)
            pendingSpeechLang = if (deviceLang == "el" || deviceCountry == "GR" || deviceCountry == "CY") {
                "el"
            } else {
                langCode.trim().ifBlank { "el" }
            }
            runOnUiThread { ensureRecordAudioAndStartSpeech() }
        }

        @JavascriptInterface
        fun stopSpeechToText() {
            runOnUiThread {
                // Μόνο stop — το cancel σβήνει τα αποτελέσματα πριν φτάσουν στο chat.
                try { speechRecognizer?.stopListening() } catch (_: Exception) {}
            }
        }

        @JavascriptInterface
        fun geocodeAddress(query: String?, requestId: String?) {
            val q = query?.trim().orEmpty()
            val id = requestId?.trim().orEmpty()
            thread(name = "geocodeAddress") {
                val results = try {
                    geocodeAddressJson(q)
                } catch (e: Exception) {
                    Log.e(TAG, "geocodeAddress error: $e")
                    "[]"
                }
                val idJs = JSONObject.quote(id)
                safeEval("if(typeof window.__onNativeGeocode==='function'){window.__onNativeGeocode($idJs, $results);}")
            }
        }

        @JavascriptInterface
        fun reverseGeocode(lat: String?, lon: String?, requestId: String?) {
            val id = requestId?.trim().orEmpty()
            thread(name = "reverseGeocode") {
                val results = try {
                    reverseGeocodeJson(lat, lon)
                } catch (e: Exception) {
                    Log.e(TAG, "reverseGeocode error: $e")
                    "[]"
                }
                val idJs = JSONObject.quote(id)
                safeEval("if(typeof window.__onNativeReverse==='function'){window.__onNativeReverse($idJs, $results);}")
            }
        }

        @JavascriptInterface
        fun placeAutocomplete(query: String?, requestId: String?) {
            val q = query?.trim().orEmpty()
            val id = requestId?.trim().orEmpty()
            thread(name = "placeAutocomplete") {
                val results = try {
                    placeAutocompleteJson(q)
                } catch (e: Exception) {
                    Log.e(TAG, "placeAutocomplete error: $e")
                    "[]"
                }
                val idJs = JSONObject.quote(id)
                safeEval("if(typeof window.__onNativePlaces==='function'){window.__onNativePlaces($idJs, $results);}")
            }
        }

        @JavascriptInterface
        fun placeDetails(placeId: String?, requestId: String?) {
            val pid = placeId?.trim().orEmpty()
            val id = requestId?.trim().orEmpty()
            thread(name = "placeDetails") {
                val results = try {
                    placeDetailsJson(pid)
                } catch (e: Exception) {
                    Log.e(TAG, "placeDetails error: $e")
                    "null"
                }
                val idJs = JSONObject.quote(id)
                safeEval("if(typeof window.__onNativePlaceDetails==='function'){window.__onNativePlaceDetails($idJs, $results);}")
            }
        }
    }

    private fun geocodeAddressJson(query: String): String {
        if (query.length < 2 || !Geocoder.isPresent()) return "[]"
        val geocoder = Geocoder(this, Locale("el", "GR"))
        val tries = ArrayList<String>()
        val low = query.lowercase(Locale.ROOT)
        val gate = Regex("(?:gate|πύλη|πυλη)\\s*[eε]?\\s*(\\d{1,2})", RegexOption.IGNORE_CASE).find(query)
        if (gate != null) {
            val n = gate.groupValues[1]
            tries.add("Πύλη Ε$n Πειραιάς")
            tries.add("Piraeus Port Gate E$n")
            tries.add("Gate E$n Piraeus")
        }
        tries.add(query)
        if (low.contains("λιμάν") || low.contains("λιμαν") || low.contains("port") || low.contains("harbour") || low.contains("harbor")) {
            tries.add("$query λιμάνι")
            tries.add("Piraeus Port")
        }
        if (!low.contains("ελλάδα") && !low.contains("ellada") && !low.contains("greece")) {
            tries.add("$query, Ελλάδα")
        }
        if (!query.any { it.isDigit() } && !low.contains("hotel") && !low.contains("ξενοδοχ")) {
            tries.add("$query hotel, Ελλάδα")
        }
        val out = JSONArray()
        val seen = HashSet<String>()
        for (tryQ in tries) {
            val list = try {
                @Suppress("DEPRECATION")
                geocoder.getFromLocationName(tryQ, 8, 34.80, 19.30, 41.80, 28.25)
            } catch (e: Exception) {
                Log.e(TAG, "Geocoder lookup failed for $tryQ: $e")
                null
            }
            if (list.isNullOrEmpty()) continue
            for (a in list) {
                val lat = a.latitude
                val lon = a.longitude
                if (!lat.isFinite() || !lon.isFinite()) continue
                val key = String.format(Locale.US, "%.5f,%.5f", lat, lon)
                if (!seen.add(key)) continue
                val obj = JSONObject()
                obj.put("lat", lat)
                obj.put("lon", lon)
                obj.put("display_name", a.getAddressLine(0) ?: "")
                obj.put("name", a.featureName ?: "")
                obj.put("road", a.thoroughfare ?: "")
                obj.put("house_number", a.subThoroughfare ?: "")
                obj.put("city", a.locality ?: a.subAdminArea ?: "")
                obj.put("suburb", a.subLocality ?: "")
                obj.put("postcode", a.postalCode ?: "")
                if (obj.optString("postcode").isBlank()) {
                    val line0 = obj.optString("display_name")
                    val m = Regex("\\b(\\d{5})\\b").find(line0)
                    if (m != null) obj.put("postcode", m.groupValues[1])
                }
                out.put(obj)
            }
            if (out.length() > 0) break
        }
        return out.toString()
    }

    private fun reverseGeocodeJson(latStr: String?, lonStr: String?): String {
        val lat = latStr?.replace(",", ".")?.toDoubleOrNull() ?: return "[]"
        val lon = lonStr?.replace(",", ".")?.toDoubleOrNull() ?: return "[]"
        if (!Geocoder.isPresent()) return "[]"
        val geocoder = Geocoder(this, Locale("el", "GR"))
        val list = try {
            @Suppress("DEPRECATION")
            geocoder.getFromLocation(lat, lon, 5)
        } catch (e: Exception) {
            Log.e(TAG, "Geocoder reverse failed: $e")
            null
        }
        if (list.isNullOrEmpty()) return "[]"
        val out = JSONArray()
        for (a in list) {
            if (!a.latitude.isFinite() || !a.longitude.isFinite()) continue
            out.put(addressToJson(a))
        }
        return out.toString()
    }

    private fun addressToJson(a: android.location.Address): org.json.JSONObject {
        val obj = JSONObject()
        obj.put("lat", a.latitude)
        obj.put("lon", a.longitude)
        obj.put("display_name", a.getAddressLine(0) ?: "")
        obj.put("name", a.featureName ?: "")
        obj.put("road", a.thoroughfare ?: "")
        obj.put("house_number", a.subThoroughfare ?: "")
        obj.put("city", a.locality ?: a.subAdminArea ?: "")
        obj.put("suburb", a.subLocality ?: "")
        obj.put("postcode", a.postalCode ?: "")
        if (obj.optString("postcode").isBlank()) {
            val line0 = obj.optString("display_name")
            val m = Regex("\\b(\\d{5})\\b").find(line0)
            if (m != null) obj.put("postcode", m.groupValues[1])
        }
        return obj
    }

    private fun initPlaces() {
        val key = BuildConfig.MAPS_API_KEY
        if (key.isBlank()) return
        try {
            if (!Places.isInitialized()) {
                Places.initialize(applicationContext, key, Locale("el", "GR"))
            }
            placesClient = Places.createClient(this)
        } catch (e: Exception) {
            Log.e(TAG, "Places init failed: $e")
        }
    }

    private fun placeAutocompleteJson(query: String): String {
        if (query.length < 2) return "[]"
        val client = placesClient ?: return "[]"
        if (placesToken == null) placesToken = AutocompleteSessionToken.newInstance()
        val request = FindAutocompletePredictionsRequest.builder()
            .setQuery(query)
            .setCountries(listOf("GR"))
            .setSessionToken(placesToken)
            .setLocationBias(
                RectangularBounds.newInstance(
                    LatLng(34.80, 19.30),
                    LatLng(41.80, 28.25)
                )
            )
            .build()
        val resp = try {
            Tasks.await(client.findAutocompletePredictions(request), 8, TimeUnit.SECONDS)
        } catch (e: Exception) {
            Log.e(TAG, "Places autocomplete failed: $e")
            return "[]"
        }
        val out = JSONArray()
        for (p in resp.autocompletePredictions) {
            val types = p.placeTypes.map { it.name.lowercase(Locale.ROOT) }
            val lodging = types.any { it.contains("lodging") || it.contains("hotel") }
            val port = types.any { it.contains("port") || it.contains("transit") }
            val obj = JSONObject()
            obj.put("place_id", p.placeId)
            obj.put("name", p.getPrimaryText(null).toString())
            obj.put("subtitle", p.getSecondaryText(null).toString())
            obj.put("display_name", p.getFullText(null).toString())
            obj.put("types", JSONArray(types))
            obj.put("class", if (lodging) "tourism" else "place")
            obj.put("type", when {
                lodging -> "hotel"
                port -> "port"
                else -> "address"
            })
            out.put(obj)
        }
        return out.toString()
    }

    private fun placeDetailsJson(placeId: String): String {
        if (placeId.isBlank()) return "null"
        val client = placesClient ?: return "null"
        val fields = listOf(
            Place.Field.ID,
            Place.Field.NAME,
            Place.Field.LAT_LNG,
            Place.Field.ADDRESS,
            Place.Field.ADDRESS_COMPONENTS,
            Place.Field.TYPES
        )
        val request = FetchPlaceRequest.builder(placeId, fields)
            .setSessionToken(placesToken)
            .build()
        val resp = try {
            Tasks.await(client.fetchPlace(request), 8, TimeUnit.SECONDS)
        } catch (e: Exception) {
            Log.e(TAG, "Places details failed: $e")
            return "null"
        } finally {
            placesToken = null
        }
        val place = resp.place
        val ll = place.latLng ?: return "null"
        val obj = JSONObject()
        obj.put("place_id", place.id ?: placeId)
        obj.put("name", place.name ?: "")
        obj.put("display_name", place.address ?: place.name ?: "")
        obj.put("lat", ll.latitude)
        obj.put("lon", ll.longitude)
        obj.put("road", addrComponent(place, "route"))
        obj.put("house_number", addrComponent(place, "street_number"))
        obj.put("city", addrComponent(place, "locality").ifBlank { addrComponent(place, "administrative_area_level_3") })
        obj.put("suburb", addrComponent(place, "sublocality").ifBlank { addrComponent(place, "sublocality_level_1") })
        obj.put("postcode", addrComponent(place, "postal_code"))
        val types = place.types?.map { it.name.lowercase(Locale.ROOT) } ?: emptyList()
        obj.put("types", JSONArray(types))
        val lodging = types.any { it.contains("lodging") || it.contains("hotel") }
        obj.put("class", if (lodging) "tourism" else "place")
        obj.put("type", if (lodging) "hotel" else "address")
        return obj.toString()
    }

    private fun addrComponent(place: Place, type: String): String {
        val comps = place.addressComponents?.asList() ?: return ""
        for (c in comps) {
            if (c.types.contains(type)) return c.name
        }
        return ""
    }

    private fun sanitizePhone(phone: String): String =
        phone.trim().filterIndexed { index, char -> char.isDigit() || (char == '+' && index == 0) }

    private fun openExternalIntent(action: String, uri: String) {
        runOnUiThread {
            try {
                startActivity(Intent(action, Uri.parse(uri)))
            } catch (e: Exception) {
                Log.e(TAG, "Unable to open $uri", e)
                Toast.makeText(this, "Δεν βρέθηκε κατάλληλη εφαρμογή", Toast.LENGTH_SHORT).show()
            }
        }
    }

    /** Honor/Huawei WebView κολλάει αν φορτώσει mailto: μέσα στο WebView — πάντα Intent. */
    private fun openMailto(raw: String) {
        runOnUiThread {
            try {
                val addr = raw.removePrefix("mailto:").substringBefore('?').trim()
                if (addr.isBlank()) return@runOnUiThread
                val intent = Intent(Intent.ACTION_SENDTO).apply {
                    data = Uri.parse("mailto:$addr")
                    putExtra(Intent.EXTRA_EMAIL, arrayOf(addr))
                }
                startActivity(Intent.createChooser(intent, "Email"))
            } catch (e: Exception) {
                Log.e(TAG, "Unable to open mailto $raw", e)
                Toast.makeText(this, "Δεν βρέθηκε εφαρμογή email", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun ensureRecordAudioAndStartSpeech() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQ_RECORD_AUDIO)
            return
        }
        startSpeechListening(pendingSpeechLang)
    }

    private fun createClientSpeechRecognizer(): SpeechRecognizer? {
        return try {
            SpeechRecognizer.createSpeechRecognizer(this)
        } catch (e: Exception) {
            Log.e(TAG, "createSpeechRecognizer error: $e")
            null
        }
    }

    private fun speechLocaleFor(langCode: String): String {
        val device = Locale.getDefault()
        val deviceLang = device.language.lowercase(Locale.ROOT)
        val deviceCountry = device.country.uppercase(Locale.ROOT)
        // Στην Ελλάδα / ελληνικό κινητό → πάντα ελληνική αναγνώριση,
        // ακόμα κι αν η UI της εφαρμογής είναι στα αγγλικά.
        if (deviceLang == "el" || deviceCountry == "GR" || deviceCountry == "CY") {
            return "el-GR"
        }
        return if (langCode.trim().lowercase(Locale.ROOT) == "en") "en-US" else "el-GR"
    }

    private fun buildSpeechIntent(langCode: String): Intent {
        val locale = speechLocaleFor(langCode)
        Log.d(TAG, "speech locale=$locale requested=$langCode device=${Locale.getDefault()}")
        return Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, locale)
            putExtra(RecognizerIntent.EXTRA_ONLY_RETURN_LANGUAGE_PREFERENCE, true)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 2800L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 2200L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 12000L)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)
        }
    }

    private fun bestSpeechText(results: Bundle?): String {
        val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
        return list.maxByOrNull { it.trim().length }?.trim().orEmpty()
    }

    private fun resetClientSpeechRecognizer() {
        try {
            speechRecognizer?.destroy()
        } catch (_: Exception) {}
        speechRecognizer = null
    }

    private fun startSpeechListening(langCode: String) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            notifySpeechToJs("", "unavailable")
            return
        }
        resetClientSpeechRecognizer()
        speechRecognizer = createClientSpeechRecognizer()
        speechRecognizer?.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onError(error: Int) {
                    Log.w(TAG, "speech onError: $error")
                    val err = when (error) {
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permission"
                        SpeechRecognizer.ERROR_NO_MATCH -> "no_match"
                        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "timeout"
                        else -> "error"
                    }
                    notifySpeechToJs("", err)
                }
                override fun onResults(results: Bundle?) {
                    notifySpeechToJs(bestSpeechText(results), "")
                }
                override fun onPartialResults(partialResults: Bundle?) {
                    val text = bestSpeechText(partialResults)
                    if (text.isNotEmpty()) notifySpeechPartialToJs(text)
                }
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
        if (speechRecognizer == null) {
            notifySpeechToJs("", "unavailable")
            return
        }
        val intent = buildSpeechIntent(langCode)
        try {
            speechRecognizer?.startListening(intent)
        } catch (e: Exception) {
            Log.e(TAG, "startSpeechListening error: $e")
            notifySpeechToJs("", "error")
        }
    }

    private fun notifySpeechToJs(text: String, error: String) {
        safeEval("try{if(window.__onAppSpeechResult)window.__onAppSpeechResult(${JSONObject.quote(text)},${JSONObject.quote(error)});}catch(e){}")
    }

    private fun notifySpeechPartialToJs(text: String) {
        safeEval("try{if(window.__onAppSpeechPartial)window.__onAppSpeechPartial(${JSONObject.quote(text)});}catch(e){}")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d("START_TEST", "MainActivity started")
        initPlaces()

        createNotificationChannelOnStartup()
        VpsConfig.appContext = applicationContext
        VpsConfig.load(this)
        kotlin.concurrent.thread { VpsHttp.resolveApiUrl(this, force = true) }
        signInAnonymouslyNative()

        webView = WebView(this)
        webView.isFocusable = true
        webView.isFocusableInTouchMode = true
        webView.setBackgroundColor(android.graphics.Color.BLACK)
        setContentView(webView)
        setupWebView()
        webView.loadUrl("file:///android_asset/client.html")
        mainHandler.postDelayed({ ensurePageLoaded() }, 5000L)

        captureIntentAction(intent)
        e2eAutoPrice = intent.getBooleanExtra("e2e_auto_price", false)
        e2eUiFlow = intent.getBooleanExtra("e2e_ui_flow", false)

        Handler(Looper.getMainLooper()).postDelayed({
            fetchFcmToken()
        }, 2000L)

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (!::webView.isInitialized) {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                    return
                }
                webView.evaluateJavascript(
                    "(function(){try{return !!(window.__clientHandleAndroidBack&&window.__clientHandleAndroidBack());}catch(e){return false;}})();"
                ) { result ->
                    runOnUiThread {
                        val handled = result == "true"
                        if (!handled) {
                            if (webView.canGoBack()) {
                                webView.goBack()
                            } else {
                                isEnabled = false
                                onBackPressedDispatcher.onBackPressed()
                            }
                        }
                    }
                }
            }
        })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureIntentAction(intent)
        processPendingOpenActions()
    }

    private fun captureIntentAction(intent: Intent?) {
        if (intent == null) return
        e2eUiFlow = intent.getBooleanExtra("e2e_ui_flow", e2eUiFlow)
        e2eAutoPrice = intent.getBooleanExtra("e2e_auto_price", e2eAutoPrice)
        if (intent.getBooleanExtra("openClientT200", false) || intent.getBooleanExtra("openClientUnconfirmed", false)) {
            pendingClientT200BookingId = intent.getStringExtra("bookingId")
            Log.d(TAG, "Captured openClientT200 for booking=${pendingClientT200BookingId}")
        }
        // ✅ ΝΕΟ: οδηγός δεν βρήκε πελάτη
        if (intent.getBooleanExtra("openDriverCannotFind", false)) {
            pendingDriverCannotFindBookingId = intent.getStringExtra("bookingId")
            Log.d(TAG, "Captured openDriverCannotFind for booking=${pendingDriverCannotFindBookingId}")
        }
        // ✅ Driver ready: άνοιγμα πράσινου overlay από notification χωρίς αλλαγή ροής
        if (intent.getBooleanExtra("openDriverReady", false)) {
            pendingDriverReadyBookingId = intent.getStringExtra("bookingId")
            Log.d(TAG, "Captured openDriverReady for booking=${pendingDriverReadyBookingId}")
        }
    }

    private fun processPendingOpenActions() {
        if (!pageReady) return

        val bookingId = pendingClientT200BookingId
        if (!bookingId.isNullOrBlank()) {
            pendingClientT200BookingId = null
            Handler(Looper.getMainLooper()).postDelayed({
                openClientT200Overlay(bookingId)
            }, 250L)
        }

        // ✅ ΝΕΟ: άνοιγμα νέου cannot find overlay
        val cannotFindId = pendingDriverCannotFindBookingId
        if (!cannotFindId.isNullOrBlank()) {
            pendingDriverCannotFindBookingId = null
            Handler(Looper.getMainLooper()).postDelayed({
                openDriverCannotFindOverlay(cannotFindId)
            }, 250L)
        }

        // ✅ Driver ready: άνοιγμα πράσινου overlay από notification
        val driverReadyId = pendingDriverReadyBookingId
        if (!driverReadyId.isNullOrBlank()) {
            pendingDriverReadyBookingId = null
            Handler(Looper.getMainLooper()).postDelayed({
                openDriverReadyOverlay(driverReadyId)
            }, 250L)
        }
    }

    private fun openClientT200Overlay(bookingId: String) {
        startClientVpsBookingWatch(bookingId)
        openClientT200ViaVps(bookingId)
    }

    // ✅ ΝΕΟ: ανοίγει νέο driverCannotFindOverlay όταν η εφαρμογή ανοίξει από notification
    private fun openDriverCannotFindOverlay(bookingId: String) {
        FirebaseDatabase.getInstance().getReference("bookings/$bookingId")
            .addListenerForSingleValueEvent(object : ValueEventListener {
                override fun onDataChange(snapshot: DataSnapshot) {
                    if (!snapshot.exists()) return
                    val b = snapshot.getValue() as? Map<*, *> ?: return
                    val status = (b["status"] as? String)?.trim()?.lowercase(Locale.ROOT) ?: ""
                    val blocked = setOf("cancelled", "canceled", "driver_cancelled", "client_cancelled", "no_driver", "retry_no_driver", "expired", "done", "completed", "closed", "no_show", "cannot_find_client", "cannot_find_closed")
                    if (status in blocked) {
                        fullRecoverAfterTerminal("openDriverCannotFindOverlay:$status")
                        return
                    }
                    val driverCannotFindClient = b["driverCannotFindClient"] as? Boolean == true
                    if (!driverCannotFindClient) return

                    val safeId = bookingId.replace("\\", "\\\\").replace("'", "\\'")
                    safeEval(
                        "try{" +
                                "if(typeof window._showCannotFindOverlay==='function'){" +
                                "window._showCannotFindOverlay('$safeId');" +
                                "}" +
                                "}catch(e){}"
                    )
                }

                override fun onCancelled(error: DatabaseError) {
                    Log.e(TAG, "openDriverCannotFindOverlay cancelled: ${error.message}")
                }
            })
    }

    // ✅ Driver ready: άνοιγμα υπάρχοντος πράσινου overlay όταν ανοίγει η εφαρμογή από notification
    private fun openDriverReadyOverlay(bookingId: String) {
        openDriverReadyViaVps(bookingId)
        mainHandler.postDelayed({ openDriverReadyViaVps(bookingId) }, 800)
        mainHandler.postDelayed({ openDriverReadyViaVps(bookingId) }, 2500)
    }

    private fun isTerminalStatusForClientRecover(status: String): Boolean {
        return status in setOf(
            "no_driver",
            "retry_no_driver",
            "cancelled",
            "canceled",
            "client_cancelled",
            "expired",
            "timeout",
            "done",
            "completed",
            "closed",
            "no_show",
            "cannot_find_client",
            "cannot_find_closed"
        )
    }

    private fun fullRecoverAfterTerminal(reason: String = "terminal") {
        runOnUiThread {
            try {
                val now = System.currentTimeMillis()
                if (now - lastTerminalRecoverAt < 1500L) return@runOnUiThread
                lastTerminalRecoverAt = now

                stopBookingWatcher()

                pendingClientT200BookingId = null
                pendingDriverCannotFindBookingId = null
                pendingDriverReadyBookingId = null

                unconfirmedCheckRunnable?.let { mainHandler.removeCallbacks(it) }
                unconfirmedCheckRunnable = null

                if (::webView.isInitialized) {
                    try { webView.resumeTimers() } catch (_: Exception) {}
                    try { webView.onResume() } catch (_: Exception) {}

                    safeEval(
                        """
                        try{
                            window.activeBookingId=null;
                            window.currentBookingId=null;
                            window.pendingBookingId=null;
                            window._cfmCurrentBookingId=null;
                            window.__ANDROID_TERMINAL_RECOVER_AT=Date.now();
                            if(typeof window.cancelClientUnconfirmedCheck==='function'){
                                try{ window.cancelClientUnconfirmedCheck(); }catch(e){}
                            }
                            if(typeof window.rescanForActiveBooking==='function'){
                                try{ window.rescanForActiveBooking(); }catch(e){}
                            }
                            if(typeof window.restartFirebaseListeners==='function'){
                                try{ window.restartFirebaseListeners(); }catch(e){}
                            }
                            if(typeof window.rebindFirebaseListeners==='function'){
                                try{ window.rebindFirebaseListeners(); }catch(e){}
                            }
                            if(typeof window.recoverClientAfterTerminal==='function'){
                                try{ window.recoverClientAfterTerminal(); }catch(e){}
                            }
                        }catch(e){}
                        """.trimIndent()
                    )
                }

                fetchFcmToken()
                Log.d(TAG, "✅ FULL CLIENT RECOVER DONE: $reason")
            } catch (e: Exception) {
                Log.e(TAG, "fullRecoverAfterTerminal error", e)
            }
        }
    }

    private fun stopBookingWatcherLocked() {
        try {
            val bid = activeBookingWatcherId
            val listener = activeBookingWatcher
            if (bid != null && listener != null) {
                FirebaseDatabase.getInstance().getReference("bookings/$bid").removeEventListener(listener)
            }
            clearVpsWatcherJsFiredKeys(bid)
        } catch (_: Exception) {}
        activeBookingWatcher = null
        activeBookingWatcherId = null
        bookingWatcherStartingId = null
    }

    private fun stopBookingWatcher() {
        synchronized(bookingWatcherLock) {
            stopBookingWatcherLocked()
        }
    }

    private val shownClientNotifications = mutableSetOf<String>()

    private fun showClientLocalNotification(bookingId: String, tag: String, title: String, body: String, intentExtra: String) {
        val dedupeKey = "${tag}_$bookingId"
        if (shownClientNotifications.contains(dedupeKey)) return
        shownClientNotifications.add(dedupeKey)

        runOnUiThread {
            try {
                val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                val openIntent = Intent(this, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    putExtra(intentExtra, true)
                    putExtra("bookingId", bookingId)
                }
                val pendingIntent = PendingIntent.getActivity(
                    this, ("${tag}_$bookingId").hashCode(), openIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                val notification = NotificationCompat.Builder(this, "booking_reminder")
                    .setSmallIcon(android.R.drawable.ic_dialog_alert)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                    .setPriority(NotificationCompat.PRIORITY_MAX)
                    .setAutoCancel(true)
                    .setContentIntent(pendingIntent)
                    .setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
                    .setVibrate(longArrayOf(0, 400, 200, 400, 200, 800))
                    .build()
                manager.notify("${tag}_$bookingId", 0, notification)
                Log.d(TAG, "✅ Local notification shown: $tag for $bookingId")
            } catch (e: Exception) {
                Log.e(TAG, "showClientLocalNotification error: $e")
            }
        }
    }

    private fun createNotificationChannelOnStartup() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.deleteNotificationChannel("driver_arrived")

        val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        val channel = NotificationChannel(
            "driver_arrived",
            "Άφιξη Οδηγού",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Ειδοποίηση όταν ο οδηγός φτάσει"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 400, 200, 400, 200, 800)
            setSound(soundUri, audioAttributes)
            enableLights(true)
            lightColor = 0xFFFFD700.toInt()
        }
        manager.createNotificationChannel(channel)

        val bookingChannel = NotificationChannel(
            "booking_reminder",
            "Υπενθυμίσεις Κράτησης",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Ειδοποιήσεις για σημαντικά reminders κράτησης"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 400, 200, 400, 200, 800)
            setSound(soundUri, audioAttributes)
            enableLights(true)
            lightColor = 0xFFFFD700.toInt()
        }
        manager.createNotificationChannel(bookingChannel)

        Log.d(TAG, "Notification channels created on startup")
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        val s = webView.settings
        s.javaScriptEnabled = true
        s.domStorageEnabled = true
        @Suppress("DEPRECATION")
        run { s.databaseEnabled = true }
        s.cacheMode = WebSettings.LOAD_DEFAULT
        s.allowFileAccess = true
        s.allowContentAccess = true
        // fontScale=1.0 στο attachBaseContext → σταθερό WebView zoom σε όλα τα κινητά
        s.textZoom = 100
        s.useWideViewPort = true
        s.loadWithOverviewMode = true
        s.setSupportZoom(false)
        s.builtInZoomControls = false
        s.displayZoomControls = false

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
            s.allowFileAccessFromFileURLs = true
            s.allowUniversalAccessFromFileURLs = true
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            s.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
        }

        webView.addJavascriptInterface(AndroidBridge(), "ClientBridge")

        webView.webViewClient = object : WebViewClient() {
            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                Log.e(TAG, "WebView renderer exited (didCrash=${detail?.didCrash() == true})")
                runOnUiThread {
                    try { (view?.parent as? android.view.ViewGroup)?.removeView(view) } catch (_: Exception) {}
                    try { view?.destroy() } catch (_: Exception) {}
                    if (!isFinishing && !isDestroyed) {
                        try { recreate() } catch (e: Exception) { Log.e(TAG, "WebView recovery failed", e) }
                    }
                }
                return true
            }
            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?
            ): Boolean {
                val url = request?.url?.toString() ?: return false
                val scheme = request.url?.scheme ?: return false

                return when (scheme) {
                    "mailto" -> {
                        openMailto(url)
                        true
                    }
                    "tel", "sms", "smsto" -> {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        } catch (e: Exception) {
                            Log.e(TAG, "Error: $e")
                        }
                        true
                    }
                    "whatsapp" -> {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        } catch (e: Exception) {
                            Log.e(TAG, "Error: $e")
                        }
                        true
                    }
                    "https", "http" -> {
                        if (url.contains("wa.me/") || url.contains("api.whatsapp.com/")) {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            } catch (e: Exception) {
                                Log.e(TAG, "Error: $e")
                            }
                            true
                        } else {
                            false
                        }
                    }
                    else -> false
                }
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: android.webkit.WebResourceError?
            ) {
                super.onReceivedError(view, request, error)
                Log.e(TAG, "WebView error: ${error?.description} url=${request?.url}")
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                Log.d(TAG, "Page finished: $url")
                pageReady = true
                val apiNow = VpsConfig.API_URL.ifBlank { "http://167.233.49.140" }
                val quoted = org.json.JSONObject.quote(apiNow)
                runOnUiThread {
                    try {
                        Toast.makeText(this@MainActivity, "Taxi VPS 3.0 loaded", Toast.LENGTH_SHORT).show()
                    } catch (_: Exception) {}
                    safeEval("window.__ANDROID_READY__ = true;")
                    safeEval("""
                        try {
                          window.TAXI_API_URL = $quoted;
                          localStorage.setItem('taxi_last_api_url', $quoted);
                        } catch(e) {}
                    """.trimIndent())
                    wakeClientWebApp()
                    scheduleClientWake()
                    fcmToken?.let { token ->
                        val escaped = token.replace("\\", "\\\\").replace("\"", "\\\"")
                        safeEval("""if(typeof window.__onClientFcmToken==='function'){window.__onClientFcmToken("$escaped");}""")
                    }
                    processPendingOpenActions()
                    mainHandler.postDelayed({ requestNotificationPermission() }, 2500L)
                    injectClientBootstrap()
                    mainHandler.postDelayed({ injectClientBootstrap() }, 3500L)
                    if (e2eAutoPrice) {
                        mainHandler.postDelayed({ injectE2EFormAndPrice() }, 6500L)
                    }
                    if (e2eUiFlow) {
                        mainHandler.postDelayed({ injectE2EUIFlowTest() }, 7000L)
                    }
                    mainHandler.postDelayed({ verifyClientHtmlBuild() }, 800L)
                }
                kotlin.concurrent.thread {
                    val api = VpsHttp.resolveApiUrl(this@MainActivity, force = true)
                    val quotedResolved = org.json.JSONObject.quote(api)
                    runOnUiThread {
                        safeEval("""
                            try {
                              window.TAXI_API_URL = $quotedResolved;
                              localStorage.setItem('taxi_last_api_url', $quotedResolved);
                            } catch(e) {}
                        """.trimIndent())
                    }
                }
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
                Log.d(TAG, "console: ${consoleMessage.message()} @${consoleMessage.lineNumber()}")
                return true
            }
        }
    }

    private fun safeEval(js: String) {
        runOnUiThread {
            try {
                webView.evaluateJavascript(js, null)
            } catch (e: Exception) {
                Log.e(TAG, "evaluateJavascript error", e)
            }
        }
    }

    private fun safeEvalResult(js: String, onResult: (String?) -> Unit) {
        runOnUiThread {
            try {
                webView.evaluateJavascript(js) { value -> onResult(value) }
            } catch (e: Exception) {
                Log.e(TAG, "evaluateJavascript error", e)
                onResult(null)
            }
        }
    }

    private fun verifyClientHtmlBuild() {
        if (!::webView.isInitialized) return
        safeEvalResult(
            """
            (function(){
              try {
                var html = document.documentElement.innerHTML || '';
                var hasVps = (window.__CLIENT_BUILD_ID === '3.0-VPS');
                var hasSdk = html.indexOf('taxi-rtdb-sdk.js') >= 0;
                var noFirebaseCdn = html.indexOf('gstatic.com/firebase') < 0;
                var badge = document.getElementById('clientBuildBadge');
                var hasBadge = badge && badge.textContent && badge.textContent.indexOf('3.0 VPS') >= 0;
                return (hasVps && hasSdk && noFirebaseCdn && hasBadge) ? 'OK' : 'OLD';
              } catch(e) { return 'OLD'; }
            })();
            """.trimIndent()
        ) { result ->
            val ok = result?.contains("OK") == true
            Log.d(TAG, "client.html verify: raw=$result ok=$ok version=${BuildConfig.VERSION_NAME}")
            if (!ok && !isFinishing) {
                AlertDialog.Builder(this)
                    .setTitle("Παλιό APK")
                    .setMessage(
                        "Αυτό ΔΕΝ είναι η σωστή έκδοση (3.0 VPS).\n\n" +
                        "1) Απεγκατάσταση Taxi\n" +
                        "2) Android Studio: άνοιξε ΜΟΝΟ αυτό το project:\n" +
                        "Νέος φάκελος (2)\\AndroidStudioProjects\\ClientMainActivity\n" +
                        "3) Build > Clean Project > Rebuild\n" +
                        "4) Run (ή διπλόκλικ INSTALL-VPS.bat)"
                    )
                    .setPositiveButton("OK", null)
                    .show()
            }
        }
    }

    private fun injectE2EUIFlowTest() {
        safeEval(
            """
            try {
              var R = [];
              function ok(n, c) { R.push(n + (c ? ':PASS' : ':FAIL')); }
              function vis(id) {
                var el = document.getElementById(id);
                if (!el) return false;
                var s = window.getComputedStyle(el);
                return s.display !== 'none' && s.visibility !== 'hidden' && Number(s.opacity) !== 0;
              }
              try { localStorage.removeItem('clientRouteMode'); sessionStorage.removeItem('clientRouteMode'); } catch(e) {}
              try { localStorage.removeItem('clientTermsAccepted_v1'); } catch(e) {}
              if (typeof window.__showRouteChoiceScreen === 'function') window.__showRouteChoiceScreen();
              ok('route_screen', vis('routeChoiceScreen'));
              if (typeof window.__pickClientRoute === 'function') window.__pickClientRoute('athens_airport');
              function waitTerms(cb, n) {
                var ov = document.getElementById('clientTermsOverlayV1');
                var shown = ov && (ov.style.display === 'block' || (window.getComputedStyle && window.getComputedStyle(ov).display !== 'none'));
                if (shown || n >= 30) { cb(shown); return; }
                setTimeout(function(){ waitTerms(cb, n + 1); }, 150);
              }
              waitTerms(function(termsShown) {
                ok('terms_overlay_fresh', termsShown);
                if (typeof window.__termsAccepted === 'function') window.__termsAccepted();
                ok('terms_hidden', !vis('clientTermsOverlayV1'));
                ok('form_after_route', vis('bookingForm'));
                ok('container_visible', (function(){ var c=document.querySelector('.container'); return !!(c && window.getComputedStyle(c).display!=='none'); })());
                var btn = document.getElementById('btn');
                var fbtn = document.getElementById('btnFloatVps');
                ok('yellow_btn', !!(btn && !btn.disabled && window.getComputedStyle(btn).display!=='none'));
                ok('float_yellow_btn', !!(fbtn && window.getComputedStyle(fbtn).display!=='none'));
                ok('build_badge', !!(document.getElementById('clientBuildBadge') && document.getElementById('clientBuildBadge').textContent.indexOf('3.0 VPS')>=0));
                var pickup = document.getElementById('pickup');
                if (pickup) pickup.value = 'Syntagma Athens';
                if (typeof window.__clientShowPriceReal === 'function') {
                  window.__clientShowPriceReal();
                  ok('price_overlay', vis('priceOverlay'));
                  if (typeof window.hideOverlay === 'function') window.hideOverlay();
                  else { var po = document.getElementById('priceOverlay'); if (po) po.style.display = 'none'; }
                } else { ok('show_price_fn', false); }
                if (typeof window.__showRouteChoiceScreen === 'function') window.__showRouteChoiceScreen();
                ok('back_to_route', vis('routeChoiceScreen'));
                if (typeof window.__pickClientRoute === 'function') window.__pickClientRoute('airport_athens');
                ok('airport_mode', window._clientRouteMode === 'airport_athens');
                if (typeof window.__showRouteChoiceScreen === 'function') window.__showRouteChoiceScreen();
                ok('back_again', vis('routeChoiceScreen'));
                if (window.ClientBridge && ClientBridge.log) ClientBridge.log('E2E_UI_TEST ' + R.join(' | '));
              }, 0);
            } catch(e) {
              if (window.ClientBridge && ClientBridge.log) ClientBridge.log('E2E_UI_TEST error:' + e);
            }
            """.trimIndent()
        )
    }

    private fun injectE2EFormAndPrice() {
        safeEval(
            """
            try {
              var p = document.getElementById('pickup');
              if (p) p.value = 'Syntagma Athens';
              var n = document.getElementById('name');
              if (n) n.value = 'E2E';
              var s = document.getElementById('surname');
              if (s) s.value = 'Test';
              var ph = document.getElementById('phone');
              if (ph) ph.value = '6911111111';
              if (typeof window.__forceBookingBtn === 'function') window.__forceBookingBtn();
              if (typeof window.clientTapPrice === 'function') window.clientTapPrice(null);
              if (window.ClientBridge && ClientBridge.log) ClientBridge.log('E2E price tap sent');
            } catch(e) {
              if (window.ClientBridge && ClientBridge.log) ClientBridge.log('E2E err ' + e);
            }
            """.trimIndent()
        )
    }

    private fun injectClientBootstrap() {
        safeEval(
            """
            try {
              var mode = null;
              try { mode = sessionStorage.getItem('clientRouteMode') || localStorage.getItem('clientRouteMode'); } catch(e) {}
              if (mode === 'athens_airport' || mode === 'airport_athens') {
                if (typeof window.__pickClientRoute === 'function') window.__pickClientRoute(mode);
                else if (typeof window.selectClientRoute === 'function') window.selectClientRoute(mode);
              }
              if (typeof window.__clientFixHomeUI === 'function') window.__clientFixHomeUI();
              if (typeof window.__forceBookingBtn === 'function') window.__forceBookingBtn();
              if (localStorage.getItem('clientTermsAccepted_v1') !== '1') {
                /* fresh install: terms overlay after route — do not scroll yellow btn yet */
              } else {
                if (typeof window.__flushTermsAcceptance === 'function') window.__flushTermsAcceptance();
                if (typeof window.__ensureYellowBtnVisible === 'function') window.__ensureYellowBtnVisible();
              }
            } catch(e) {}
            """.trimIndent()
        )
    }

    private fun ensurePageLoaded() {
        if (pageReady || !::webView.isInitialized || reloadAttempted) return
        reloadAttempted = true
        Log.w(TAG, "Page not ready after timeout — reloading WebView")
        webView.reload()
        mainHandler.postDelayed({
            if (::webView.isInitialized) wakeClientWebApp()
        }, 2500L)
    }

    private fun wakeClientWebApp() {
        if (!::webView.isInitialized) return
        safeEval(
            """
            try {
              if (typeof window.__clientFixHomeUI === 'function') {
                window.__clientFixHomeUI();
              } else if (typeof window.__clientAppWake === 'function') {
                window.__clientAppWake();
              } else if (typeof window.__forceBookingBtn === 'function') {
                window.__forceBookingBtn();
              } else if (typeof window.unlockBookingBtn === 'function') {
                window.unlockBookingBtn();
              } else {
                var b = document.getElementById('btn');
                if (b) {
                  b.disabled = false;
                  b.removeAttribute('disabled');
                  b.style.opacity = '1';
                  b.style.pointerEvents = 'auto';
                  b.dataset.authUnlocked = '1';
                  var lang = window.lang || 'el';
                  b.textContent = (lang === 'en') ? 'Show price' : 'Δείξε τιμή';
                }
                var rcs = document.getElementById('routeChoiceScreen');
                var mode = null;
                try { mode = sessionStorage.getItem('clientRouteMode') || localStorage.getItem('clientRouteMode'); } catch(e) {}
                if (rcs && (mode === 'airport_athens' || mode === 'athens_airport')) {
                  rcs.style.display = 'none';
                  var rb = document.getElementById('routeBackTopBtn');
                  if (rb) rb.style.display = 'flex';
                }
              }
            } catch(e) {}
            """.trimIndent()
        )
    }

    private fun scheduleClientWake() {
        val delays = longArrayOf(300L, 1200L, 3000L)
        for (delay in delays) {
            mainHandler.postDelayed({ wakeClientWebApp() }, delay)
        }
    }

    private fun fetchFcmToken(attempt: Int = 1) {
        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { token ->
                fcmToken = token
                Log.d(TAG, "FCM token ok (attempt $attempt): $token")

                VpsAuth.getUid()?.let { uid ->
                    FirebaseDatabase.getInstance()
                        .getReference("fcmTokens/$uid")
                        .setValue(token)
                }

                val escaped = token.replace("\\", "\\\\").replace("\"", "\\\"")
                safeEval("""if(typeof window.__onClientFcmToken==='function'){window.__onClientFcmToken("$escaped");}""")
            }
            .addOnFailureListener { e ->
                Log.e(TAG, "FCM token error (attempt $attempt): $e")

                if (attempt < 2) {
                    val delayMs = 4000L
                    Log.d(TAG, "Retrying FCM token in ${delayMs / 1000}s...")
                    Handler(Looper.getMainLooper())
                        .postDelayed({ fetchFcmToken(attempt + 1) }, delayMs)
                } else {
                    Log.w(TAG, "FCM token skipped after $attempt attempts (non-blocking)")
                }
            }
    }

    private fun signInAnonymouslyNative() {
        VpsAuth.load(this)
        val existing = VpsAuth.getUid()
        if (!existing.isNullOrBlank()) {
            authReady = true
            Log.d(TAG, "Auth already exists: $existing")
            return
        }
        VpsAuth.signInAnonymously(this) { ok ->
            authReady = ok
            if (ok) {
                Log.d(TAG, "Native auth ok: ${VpsAuth.getUid()}")
                fetchFcmToken()
            } else {
                Log.e(TAG, "Native auth failed")
            }
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return

        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED

        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_NOTIF
            )
        }
    }

    override fun onStart() {
        super.onStart()
        if (::webView.isInitialized) {
            try { webView.onResume() } catch (_: Exception) {}
            try { webView.resumeTimers() } catch (_: Exception) {}
            scheduleClientWake()
        }
    }

    override fun onPause() {
        super.onPause()
        if (::webView.isInitialized) {
            try { webView.onPause() } catch (_: Exception) {}
            try { webView.pauseTimers() } catch (_: Exception) {}
        }
    }

    override fun onResume() {
        super.onResume()
        // ✅ Σβήνει όλες τις ειδοποιήσεις όταν ανοίγει η εφαρμογή
        try {
            val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                manager.activeNotifications.forEach { manager.cancel(it.tag, it.id) }
            }
        } catch (_: Exception) {}

        if (::webView.isInitialized) {
            try { webView.onResume() } catch (_: Exception) {}
            try { webView.resumeTimers() } catch (_: Exception) {}
            scheduleClientWake()
        }
    }

    override fun onDestroy() {
        stopBookingWatcher()
        unconfirmedCheckRunnable?.let { mainHandler.removeCallbacks(it) }
        try {
            speechRecognizer?.destroy()
            speechRecognizer = null
        } catch (_: Exception) {}
        try { mainHandler.removeCallbacksAndMessages(null) } catch (_: Exception) {}
        if (::webView.isInitialized) {
            try { (webView.parent as? android.view.ViewGroup)?.removeView(webView) } catch (_: Exception) {}
            try { webView.stopLoading() } catch (_: Exception) {}
            try { webView.removeJavascriptInterface("ClientBridge") } catch (_: Exception) {}
            try { webView.destroy() } catch (_: Exception) {}
        }
        super.onDestroy()

    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_RECORD_AUDIO) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startSpeechListening(pendingSpeechLang)
            } else {
                notifySpeechToJs("", "permission")
            }
        }
    }
}
