package fr.orbitalis.broadcaster

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    companion object {
        const val REQ_MEDIA_PROJECTION = 100
        const val PREFS = "OrbitalisBroadcaster"
        const val DEFAULT_URL = "https://stream.orbitalis.fr/seestar-upload"
        const val DEFAULT_TOKEN = "11293f86bb8f49f382a48f20f1c680d66addc34fc7bb40f0"
    }

    private lateinit var urlField: EditText
    private lateinit var tokenField: EditText
    private lateinit var startBtn: Button
    private lateinit var stopBtn: Button
    private lateinit var statusText: TextView
    private lateinit var mediaProjectionManager: MediaProjectionManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        urlField    = findViewById(R.id.url_field)
        tokenField  = findViewById(R.id.token_field)
        startBtn    = findViewById(R.id.start_btn)
        stopBtn     = findViewById(R.id.stop_btn)
        statusText  = findViewById(R.id.status_text)

        mediaProjectionManager =
            getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        urlField.setText(prefs.getString("url", DEFAULT_URL))
        tokenField.setText(prefs.getString("token", DEFAULT_TOKEN))

        startBtn.setOnClickListener {
            val url = urlField.text.toString().trim()
            val tok = tokenField.text.toString().trim()
            if (url.isEmpty() || tok.isEmpty()) {
                setStatus("URL et token requis", false)
                return@setOnClickListener
            }
            prefs.edit().putString("url", url).putString("token", tok).apply()
            @Suppress("DEPRECATION")
            startActivityForResult(
                mediaProjectionManager.createScreenCaptureIntent(),
                REQ_MEDIA_PROJECTION
            )
        }

        stopBtn.setOnClickListener {
            stopService(Intent(this, ScreenCaptureService::class.java))
            setStatus("Arrêté", false)
            startBtn.isEnabled = true
            stopBtn.isEnabled  = false
        }

        stopBtn.isEnabled = false
        setStatus("Prêt", false)
    }

    @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_MEDIA_PROJECTION) return

        if (resultCode == Activity.RESULT_OK && data != null) {
            val url = urlField.text.toString().trim()
            val tok = tokenField.text.toString().trim()
            val intent = Intent(this, ScreenCaptureService::class.java).apply {
                putExtra("resultCode", resultCode)
                putExtra("data", data)
                putExtra("url", url)
                putExtra("token", tok)
            }
            startForegroundService(intent)
            setStatus("Diffusion en cours — 1 image/s", true)
            startBtn.isEnabled = false
            stopBtn.isEnabled  = true
        } else {
            setStatus("Permission refusée", false)
        }
    }

    private fun setStatus(msg: String, live: Boolean) {
        statusText.text = msg
        statusText.setTextColor(
            if (live) 0xFF44EE88.toInt() else 0xFF888888.toInt()
        )
    }
}
