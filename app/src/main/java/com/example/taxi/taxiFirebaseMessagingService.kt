package com.example.taxi

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class TaxiFirebaseMessagingService : FirebaseMessagingService() {

    companion object {
        const val CHANNEL_ID = "driver_arrived"
    }

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        super.onMessageReceived(remoteMessage)

        // ✅ FIX: Διαβάζει από data (όχι notification) για Xiaomi/MIUI
        val title = remoteMessage.data["title"]
            ?: remoteMessage.notification?.title
            ?: "🚕 Ο οδηγός σας έφτασε!"

        val body = remoteMessage.data["body"]
            ?: remoteMessage.notification?.body
            ?: "Ο οδηγός σας περιμένει στο σημείο παραλαβής!"

        createNotificationChannel()
        showNotification(title, body)
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        android.util.Log.d("FCM_TOKEN", "New token: $token")
        getSharedPreferences("fcm_prefs", Context.MODE_PRIVATE)
            .edit().putString("fcm_token", token).apply()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Άφιξη Οδηγού",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Ειδοποίηση όταν ο οδηγός φτάσει"
            enableVibration(true)
            vibrationPattern = longArrayOf(300, 100, 300, 100, 600)
            setSound(soundUri, audioAttributes)
            enableLights(true)
            lightColor = 0xFFFFD700.toInt()
        }

        manager.createNotificationChannel(channel)
    }

    private fun showNotification(title: String, body: String) {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
        )

        val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setSound(soundUri)
            .setVibrate(longArrayOf(300, 100, 300, 100, 600))
            .setLights(0xFFFFD700.toInt(), 500, 500)
            .setContentIntent(pendingIntent)
            .setFullScreenIntent(pendingIntent, true)
            .build()

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(1001, notification)
    }
}

