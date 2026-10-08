package io.github.diponsaha007.chessmortem

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hands PGNs that arrive from outside to Dart (`lib/platform/incoming_pgn.dart`):
 * text shared from another app, or a .pgn file opened with this one. And the
 * other way: a game shared from the app (`lib/platform/share_pgn.dart`).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** What the app was launched with, until Dart asks for it. */
    private var pending: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "takePending") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .setMethodCallHandler { call, result ->
                val text = call.argument<String>("text")
                if (call.method == "share" && text != null) {
                    share(text, call.argument<String>("subject"))
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            }
    }

    /** Opens the system share sheet with [text], leaving this app out of it. */
    private fun share(text: String, subject: String?) {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            if (subject != null) putExtra(Intent.EXTRA_SUBJECT, subject)
        }
        val chooser = Intent.createChooser(send, "Share game")
        // The app takes shared text in, so it would offer itself here.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            chooser.putExtra(
                Intent.EXTRA_EXCLUDE_COMPONENTS,
                arrayOf(ComponentName(this, MainActivity::class.java)),
            )
        }
        startActivity(chooser)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Not on a rotation or a restore: the same intent would arrive twice.
        if (savedInstanceState == null) pending = textOf(intent)
    }

    /** The app was already open (launchMode singleTask). */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = textOf(intent) ?: return
        val dart = channel
        if (dart == null) {
            pending = text
            return
        }
        // Dart may not be listening yet (a share during startup): keep the
        // text for its first takePending instead of dropping it.
        dart.invokeMethod("incoming", text, object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(code: String, message: String?, details: Any?) {}
            override fun notImplemented() {
                pending = text
            }
        })
    }

    /** The text an intent carries, or null when it carries none we read. */
    private fun textOf(intent: Intent?): String? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_SEND ->
                intent.getStringExtra(Intent.EXTRA_TEXT)
                    ?: read(streamOf(intent))
            Intent.ACTION_VIEW -> read(intent.data)
            else -> null
        }
    }

    @Suppress("DEPRECATION")
    private fun streamOf(intent: Intent): Uri? =
        intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri

    /** A game is a few kilobytes; anything past the cap is not one. */
    private fun read(uri: Uri?): String? {
        if (uri == null) return null
        return try {
            contentResolver.openInputStream(uri)?.use { stream ->
                val bytes = ByteArray(MAX_BYTES)
                var size = 0
                while (size < MAX_BYTES) {
                    val read = stream.read(bytes, size, MAX_BYTES - size)
                    if (read < 0) break
                    size += read
                }
                String(bytes, 0, size, Charsets.UTF_8)
            }
        } catch (e: Exception) {
            null
        }
    }

    private companion object {
        const val CHANNEL = "chess_mortem/incoming"
        const val SHARE_CHANNEL = "chess_mortem/share"
        const val MAX_BYTES = 512 * 1024
    }
}
