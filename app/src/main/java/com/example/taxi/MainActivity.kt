package com.example.taxi

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.messaging.FirebaseMessaging

class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private var fcmToken: String? = null
    private var authReady: Boolean = false

    private val TAG = "ClientMainActivity"
    private val REQ_NOTIF = 1001

    inner class AndroidBridge {

        @JavascriptInterface
        fun getFcmToken(): String? = fcmToken

        @JavascriptInterface
        fun isAuthReady(): Boolean = authReady

        @JavascriptInterface
        fun log(msg: String?) {
            Log.d(TAG, "JS: ${msg ?: ""}")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        Log.d("START_TEST", "MainActivity started")

        try {
            FirebaseApp.initializeApp(this)
        } catch (e: Exception) {
            Log.e(TAG, "Firebase init error", e)
        }

        // ✅ ΚΡΙΣΙΜΟ: Δημιούργησε το channel ΑΜΕΣΑ κατά την εκκίνηση
        createNotificationChannelOnStartup()

        requestNotificationPermission()
        signInAnonymouslyNative()

        webView = WebView(this)
        setContentView(webView)
        setupWebView()

        webView.loadUrl("file:///android_asset/client.html")

        fetchFcmToken()

        // ✅ Αντικατάσταση deprecated onBackPressed()
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (::webView.isInitialized && webView.canGoBack()) {
                    webView.goBack()
                } else {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                }
            }
        })
    }

    // ✅ Δημιουργία channel κατά την εκκίνηση
    private fun createNotificationChannelOnStartup() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // 🔔 Διαγράφουμε το παλιό channel ώστε να ξαναδημιουργηθεί με τον σωστό ήχο
        // (το Android ΔΕΝ επιτρέπει αλλαγή ήχου σε existing channel)
        manager.deleteNotificationChannel("driver_arrived")

        // 🔔 TYPE_RINGTONE = πιο δυνατός ήχος (σαν κλήση), όχι TYPE_NOTIFICATION
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
            vibrationPattern = longArrayOf(0, 400, 200, 400, 200, 800) // 🔔 παλμός καμπανάκι
            setSound(soundUri, audioAttributes)                          // 🔔 Ήχος καμπανάκι
            enableLights(true)
            lightColor = 0xFFFFD700.toInt()
        }

        manager.createNotificationChannel(channel)
        Log.d(TAG, "Notification channel created on startup")
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        val s = webView.settings
        s.javaScriptEnabled = true
        s.domStorageEnabled = true
        s.databaseEnabled = true
        s.cacheMode = WebSettings.LOAD_DEFAULT
        s.allowFileAccess = true
        s.allowContentAccess = true

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
            s.allowFileAccessFromFileURLs = true
            s.allowUniversalAccessFromFileURLs = true
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            s.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
        }

        webView.addJavascriptInterface(AndroidBridge(), "ClientBridge")

        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                return false
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                safeEval("window.__ANDROID_READY__ = true;")
                fcmToken?.let { token ->
                    val escaped = token.replace("\\", "\\\\").replace("\"", "\\\"")
                    safeEval("""if(typeof window.__onClientFcmToken==='function'){window.__onClientFcmToken("$escaped");}""")
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

    private fun fetchFcmToken() {
        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { token ->
                fcmToken = token
                Log.d(TAG, "FCM token ok: $token")

                // ✅ Αποθήκευσε το token στη database
                FirebaseDatabase.getInstance()
                    .getReference("fcmTokens/${FirebaseAuth.getInstance().currentUser?.uid}")
                    .setValue(token)

                val escaped = token.replace("\\", "\\\\").replace("\"", "\\\"")
                safeEval("""if(typeof window.__onClientFcmToken==='function'){window.__onClientFcmToken("$escaped");}""")
            }
            .addOnFailureListener { e ->
                Log.e(TAG, "FCM token error", e)
            }
    }

    private fun signInAnonymouslyNative() {
        try {
            val auth = FirebaseAuth.getInstance()
            if (auth.currentUser != null) {
                authReady = true
                Log.d(TAG, "Auth already exists: ${auth.currentUser?.uid}")
                return
            }
            auth.signInAnonymously()
                .addOnSuccessListener {
                    authReady = true
                    Log.d(TAG, "Native auth ok: ${it.user?.uid}")
                }
                .addOnFailureListener { e ->
                    authReady = false
                    Log.e(TAG, "Native auth failed", e)
                }
        } catch (e: Exception) {
            authReady = false
            Log.e(TAG, "Native auth exception", e)
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_NOTIF
            )
        }
    }

    // ✅ onBackPressed αντικαταστάθηκε με OnBackPressedCallback στο onCreate()
}

