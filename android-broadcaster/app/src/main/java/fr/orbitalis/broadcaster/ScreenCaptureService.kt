package fr.orbitalis.broadcaster

import android.app.*
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

class ScreenCaptureService : Service() {

    companion object {
        const val CHANNEL_ID    = "OrbitalisBroadcastChannel"
        const val NOTIF_ID      = 1
        const val DEFAULT_INTERVAL_MS = 100L   // 10 fps par défaut
        const val JPEG_QUALITY  = 70       // 0-100
    }

    private var mediaProjection: MediaProjection?  = null
    private var virtualDisplay:  VirtualDisplay?   = null
    private var imageReader:     ImageReader?      = null
    private var captureThread:   HandlerThread?    = null
    private var handler:         Handler?          = null
    private var serverUrl: String = ""
    private var stopUrl:   String = ""
    private var token:     String = ""
    private var intervalMs: Long = DEFAULT_INTERVAL_MS
    private var running = false

    // ── Lifecycle ───────────────────────────────────────────────────────────

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Stop action from notification button
        if (intent?.action == "STOP") {
            val t = token; val u = stopUrl
            if (t.isNotEmpty() && u.isNotEmpty()) {
                Thread {
                    try { postStop(u, t) } catch (_: Exception) {}
                    Handler(Looper.getMainLooper()).post { stopSelf() }
                }.start()
            } else {
                stopSelf()
            }
            return START_NOT_STICKY
        }

        if (intent == null) { stopSelf(); return START_NOT_STICKY }

        startForeground(NOTIF_ID, buildNotification())

        val resultCode = intent.getIntExtra("resultCode", Activity.RESULT_CANCELED)
        @Suppress("DEPRECATION")
        val projData = intent.getParcelableExtra<Intent>("data")
            ?: run { stopSelf(); return START_NOT_STICKY }

        serverUrl = intent.getStringExtra("url")   ?: run { stopSelf(); return START_NOT_STICKY }
        token     = intent.getStringExtra("token") ?: run { stopSelf(); return START_NOT_STICKY }
        intervalMs = intent.getLongExtra("intervalMs", DEFAULT_INTERVAL_MS).coerceIn(100L, 5000L)

        // Dériver l'URL de stop à partir de l'URL d'upload
        stopUrl = try {
            val u = java.net.URL(serverUrl)
            val port = if (u.port != -1) ":${u.port}" else ""
            "${u.protocol}://${u.host}$port/seestar-stop"
        } catch (_: Exception) { "" }

        val mpManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        mediaProjection = mpManager.getMediaProjection(resultCode, projData)

        // Android 14+ : enregistrer le callback AVANT createVirtualDisplay
        mediaProjection!!.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() { stopSelf() }
        }, Handler(Looper.getMainLooper()))

        @Suppress("DEPRECATION")
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        (getSystemService(WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(metrics)

        // Cap at 1280px wide to limit bandwidth
        val srcW  = metrics.widthPixels
        val srcH  = metrics.heightPixels
        val scale = if (srcW > 1280) 1280.0 / srcW else 1.0
        val capW  = (srcW * scale).toInt()
        val capH  = (srcH * scale).toInt()
        val dpi   = (metrics.densityDpi * scale).toInt()

        imageReader = ImageReader.newInstance(capW, capH, PixelFormat.RGBA_8888, 2)

        virtualDisplay = mediaProjection!!.createVirtualDisplay(
            "OrbitalisBroadcast", capW, capH, dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader!!.surface, null, null
        )

        captureThread = HandlerThread("CaptureThread").also { it.start() }
        handler = Handler(captureThread!!.looper)
        running = true
        handler!!.post(captureLoop)

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        handler?.removeCallbacksAndMessages(null)
        captureThread?.quitSafely()
        virtualDisplay?.release()
        mediaProjection?.stop()
        imageReader?.close()
        super.onDestroy()
    }

    // ── Capture loop ────────────────────────────────────────────────────────

    private val captureLoop = object : Runnable {
        override fun run() {
            if (!running) return
            try { captureAndPost() } catch (_: Exception) {}
            if (running) handler?.postDelayed(this, intervalMs)
        }
    }

    private fun captureAndPost() {
        val img = imageReader?.acquireLatestImage() ?: return
        val jpegBytes: ByteArray
        try {
            val plane     = img.planes[0]
            val rowStride = plane.rowStride
            val pixStride = plane.pixelStride
            val w         = imageReader!!.width
            val h         = imageReader!!.height
            val rowPad    = rowStride - pixStride * w
            val bmpW      = w + rowPad / pixStride

            val bmp = Bitmap.createBitmap(bmpW, h, Bitmap.Config.ARGB_8888)
            bmp.copyPixelsFromBuffer(plane.buffer)

            val cropped = if (rowPad > 0) {
                val c = Bitmap.createBitmap(bmp, 0, 0, w, h)
                bmp.recycle()
                c
            } else bmp

            val out = ByteArrayOutputStream()
            cropped.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            cropped.recycle()
            jpegBytes = out.toByteArray()
        } finally {
            img.close()
        }

        postFrameHttp(jpegBytes)
    }

    // ── HTTP multipart POST ─────────────────────────────────────────────────

    private fun postFrameHttp(jpegBytes: ByteArray) {
        val boundary = "OBound"
        val prefix = ("--$boundary\r\n" +
                "Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\n" +
                "Content-Type: image/jpeg\r\n\r\n").toByteArray(Charsets.UTF_8)
        val suffix = "\r\n--$boundary--\r\n".toByteArray(Charsets.UTF_8)
        val total  = prefix.size + jpegBytes.size + suffix.size

        val encodedToken = URLEncoder.encode(token, "UTF-8")
        val url  = URL("$serverUrl?token=$encodedToken")
        val conn = url.openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.doOutput      = true
            conn.connectTimeout = 5_000
            conn.readTimeout    = 5_000
            conn.setRequestProperty(
                "Content-Type", "multipart/form-data; boundary=$boundary"
            )
            conn.setFixedLengthStreamingMode(total)

            conn.outputStream.use { os ->
                os.write(prefix)
                os.write(jpegBytes)
                os.write(suffix)
            }
            conn.responseCode   // trigger the request
        } finally {
            conn.disconnect()
        }
    }

    // ── Stop signal ─────────────────────────────────────────────────────────

    private fun postStop(url: String, tok: String) {
        val encodedToken = URLEncoder.encode(tok, "UTF-8")
        val conn = java.net.URL("$url?token=$encodedToken").openConnection() as HttpURLConnection
        try {
            conn.requestMethod  = "POST"
            conn.connectTimeout = 4_000
            conn.readTimeout    = 4_000
            conn.setFixedLengthStreamingMode(0)
            conn.responseCode
        } finally {
            conn.disconnect()
        }
    }

    // ── Notification ────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        val ch = NotificationChannel(
            CHANNEL_ID, "Orbitalis Broadcast",
            NotificationManager.IMPORTANCE_LOW
        )
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(ch)
    }

    private fun buildNotification(): Notification {
        val stopPi = PendingIntent.getService(
            this, 0,
            Intent(this, ScreenCaptureService::class.java).setAction("STOP"),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("⟡ Orbitalis — Diffusion active")
            .setContentText("Partage d'écran en cours")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_pause, "Arrêter", stopPi)
            .build()
    }
}
