package io.github.diponsaha007.chessmortem

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hands PGNs that arrive from outside to Dart (`lib/platform/incoming_pgn.dart`):
 * text shared from another app, or a .pgn file opened with this one. And the
 * other way: a game shared from the app (`lib/platform/share_game.dart`), as
 * text or as a file from the cache's shared folder.
 *
 * Every instance runs on the process's one engine ([provideFlutterEngine]).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null

    /** What the app was launched with, until Dart asks for it. */
    private var pending: String? = null

    /**
     * The process's one engine, made on first use and kept in
     * [FlutterEngineCache], so an activity created later (after Back on the
     * library, or after the system destroyed this one) reattaches to the same
     * Dart isolate. A second isolate could never analyse: Stockfish is
     * native, one per process, and outlives the isolate that started it.
     * An engine given here is not destroyed with the activity, and onStart
     * runs main() on it only if it is not running yet.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        // The application context: the engine outlives this activity. Its
        // constructor registers the plugins, which FlutterActivity does only
        // for an engine it made itself.
        val engine = FlutterEngine(context.applicationContext, flutterShellArgs.toArray())
        cache.put(ENGINE_ID, engine)
        return engine
    }

    /** A running engine is never handed a saved state over its own. */
    override fun shouldRestoreAndSaveState(): Boolean = false

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
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                val subject = call.argument<String>("subject")
                val text = call.argument<String>("text")
                val path = call.argument<String>("path")
                val mimeType = call.argument<String>("mimeType")
                val title = call.argument<String>("title") ?: "Share game"
                when {
                    call.method == "share" && text != null -> {
                        share(text, subject, title)
                        result.success(true)
                    }
                    call.method == "shareFile" && path != null && mimeType != null ->
                        result.success(shareFile(File(path), mimeType, subject))
                    else -> result.notImplemented()
                }
            }
        }
    }

    /**
     * This activity is going and the engine stays, so its handlers go with
     * it. Runs before the next activity sets its own, even when that one
     * arrives first and takes the engine.
     */
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        shareChannel?.setMethodCallHandler(null)
        channel = null
        shareChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** Opens the system share sheet with [text], leaving this app out of it. */
    private fun share(text: String, subject: String?, title: String) {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            if (subject != null) putExtra(Intent.EXTRA_SUBJECT, subject)
        }
        showChooser(send, title)
    }

    /**
     * Opens the share sheet with [file], read through the file provider. False
     * when the file is outside the folder it exposes (res/xml/share_paths.xml).
     */
    private fun shareFile(file: File, mimeType: String, subject: String?): Boolean {
        val uri = try {
            FileProvider.getUriForFile(this, "$packageName.share", file)
        } catch (e: IllegalArgumentException) {
            return false
        }
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            if (subject != null) putExtra(Intent.EXTRA_SUBJECT, subject)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        showChooser(send, "Share game")
        return true
    }

    private fun showChooser(send: Intent, title: String) {
        val chooser = Intent.createChooser(send, title)
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
        if (savedInstanceState != null) return
        val text = textOf(intent) ?: return
        // A new engine starts Dart only in onStart, and Dart then asks for
        // the text. A reused one asked when it started, so it is told.
        if (flutterEngine?.dartExecutor?.isExecutingDart == true) {
            deliver(text)
        } else {
            pending = text
        }
    }

    /** The app was already open (launchMode singleTask). */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliver(textOf(intent) ?: return)
    }

    /** Hands [text] to a running Dart. */
    private fun deliver(text: String) {
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
        const val ENGINE_ID = "main"
        const val MAX_BYTES = 512 * 1024
    }
}
