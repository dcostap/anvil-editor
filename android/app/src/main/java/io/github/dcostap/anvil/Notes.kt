package io.github.dcostap.anvil

import android.content.Context
import android.util.Log
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.text.TextRange
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest

private const val TAG = "AnvilNotes"

// A file's content version, as the Machine computes it: the SHA-256 of its bytes, in lowercase hex.
fun contentVersion(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

// How a note's bytes become editor text and back. The editor uses `\n`. A file with `\r\n` gets `\r\n` again,
// and a byte order mark stays.
data class NoteFormat(val crlf: Boolean, val bom: Boolean) {
    fun encode(text: String): ByteArray {
        val bytes = (if (crlf) text.replace("\n", "\r\n") else text).toByteArray()
        return if (bom) BOM + bytes else bytes
    }

    companion object {
        private val BOM = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())

        // Returns the text and its format, or null when the bytes are not UTF-8 text.
        fun decode(bytes: ByteArray): Pair<String, NoteFormat>? {
            val bom = bytes.size >= 3 && bytes.copyOfRange(0, 3).contentEquals(BOM)
            val text = try {
                Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes, if (bom) 3 else 0, bytes.size - if (bom) 3 else 0)).toString()
            } catch (e: CharacterCodingException) {
                return null
            }
            val crlf = text.contains("\r\n")
            return (if (crlf) text.replace("\r\n", "\n") else text) to NoteFormat(crlf, bom)
        }
    }
}

// The unsaved text of a note, kept until the Machine has it. Android can stop the app at any time.
// `base` is the file's version that the text started from, or null for a file that did not exist.
data class Recovery(val machine: String, val path: String, val base: String?, val text: String, val format: NoteFormat)

class RecoveryStore(context: Context) {
    private val folder = File(context.filesDir, "recovery")

    private fun file(machine: String, path: String) = File(folder, contentVersion("$machine\n$path".toByteArray()) + ".json")

    fun save(record: Recovery) {
        folder.mkdirs()
        val json = JSONObject().put("machine", record.machine).put("path", record.path).put("text", record.text)
            .put("base", record.base ?: JSONObject.NULL).put("crlf", record.format.crlf).put("bom", record.format.bom)
        val target = file(record.machine, record.path)
        val next = File(folder, target.name + ".new")
        next.writeText(json.toString())
        check(next.renameTo(target)) { "Cannot save the recovery record of ${record.path}" }
    }

    fun load(machine: String, path: String): Recovery? = read(file(machine, path))

    fun delete(machine: String, path: String) {
        file(machine, path).delete()
    }

    fun all(machine: String): List<Recovery> =
        folder.listFiles { f -> f.name.endsWith(".json") }.orEmpty().mapNotNull { read(it) }.filter { it.machine == machine }

    private fun read(file: File): Recovery? {
        if (!file.exists()) return null
        return try {
            val json = JSONObject(file.readText())
            Recovery(json.getString("machine"), json.getString("path"),
                if (json.isNull("base")) null else json.getString("base"), json.getString("text"),
                NoteFormat(json.getBoolean("crlf"), json.getBoolean("bom")))
        } catch (e: Exception) {
            Log.e(TAG, "Cannot read the recovery record ${file.name}", e)
            null
        }
    }
}

sealed interface NoteStatus {
    data object Loading : NoteStatus
    data object Ready : NoteStatus
    data class Failed(val message: String) : NoteStatus
}

// The note changed on the Machine while this phone had unsaved text. `theirs` is null when the file was deleted.
data class NoteConflict(val theirs: String?, val version: String?)

// One note of a Machine, open in the editor. It saves 1 second after the last change, and only over the version
// that it read: a change on the Machine gives a conflict, and the user decides. Until the Machine has the text,
// a recovery record keeps it.
class Note(val link: MachineLink, val path: String, private val recovery: RecoveryStore, scope: CoroutineScope) {
    val text = TextFieldState()
    var status by mutableStateOf<NoteStatus>(NoteStatus.Loading)
        private set
    var conflict by mutableStateOf<NoteConflict?>(null)
        private set
    var saving by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    // The text that the file has at `base`. Null when it is not known, such as for recovered text offline.
    private var savedText by mutableStateOf<String?>(null)
    private var base: String? = null
    private var format = NoteFormat(crlf = false, bom = false)
    private var stat: String? = null

    // A write whose reply did not arrive. The next save first checks whether the Machine has it.
    private var unconfirmed: Pair<String, String>? = null

    val machine get() = link.record.machine
    val dirty get() = text.text.toString() != savedText
    val editable get() = status == NoteStatus.Ready && conflict == null && link.level == "full"

    init {
        scope.launch {
            snapshotFlow { Triple(text.text.toString(), link.state == LinkState.Online, editable) }
                .collectLatest { (current, online, editable) ->
                    if (!editable || current == savedText) return@collectLatest
                    delay(300)
                    withContext(Dispatchers.IO) { keep(current) }
                    if (!online) return@collectLatest
                    delay(700)
                    // A write that starts must finish: a write without its result leaves `base` unknown.
                    withContext(NonCancellable) { save() }
                }
        }
    }

    // Reads the note, and applies a recovery record from an earlier run.
    @OptIn(ExperimentalFoundationApi::class)
    suspend fun load() {
        if (status == NoteStatus.Ready) return
        val record = withContext(Dispatchers.IO) { recovery.load(machine, path) }
        val reply = try {
            link.call("files.read", JSONObject().put("path", path))
        } catch (e: MachineError) {
            when {
                e.code == "not_found" && record != null -> return restore(record, NoteConflict(null, null))
                (e.code == "offline" || e.code == "disconnected") && record != null -> return restore(record, null)
                else -> status = NoteStatus.Failed(e.message ?: e.code)
            }
            return
        }
        val (fileText, fileFormat) = NoteFormat.decode(reply.bytes)
            ?: return run { status = NoteStatus.Failed("This file is not UTF-8 text") }
        val version = reply.result.getString("version")
        base = version
        savedText = fileText
        format = fileFormat
        when {
            record == null || record.text == fileText -> {
                if (record != null) withContext(Dispatchers.IO) { recovery.delete(machine, path) }
                replaceText(fileText)
            }
            record.base == version -> {
                format = record.format
                replaceText(record.text)
            }
            else -> {
                replaceText(record.text)
                conflict = NoteConflict(fileText, version)
            }
        }
        text.undoState.clearHistory()
        status = NoteStatus.Ready
    }

    @OptIn(ExperimentalFoundationApi::class)
    private fun restore(record: Recovery, found: NoteConflict?) {
        base = record.base
        format = record.format
        replaceText(record.text)
        text.undoState.clearHistory()
        conflict = found
        status = NoteStatus.Ready
    }

    private fun keep(current: String) {
        try {
            recovery.save(Recovery(machine, path, base, current, format))
        } catch (e: Exception) {
            Log.e(TAG, "Cannot keep the unsaved text of $path", e)
        }
    }

    // Writes the text to the Machine if it changed.
    suspend fun save() {
        if (saving || !editable) return
        val current = text.text.toString()
        if (current == savedText) return
        saving = true
        try {
            unconfirmed?.let { (sentText, sentVersion) ->
                val version = link.call("files.read", JSONObject().put("path", path)).result.optString("version")
                if (version == sentVersion) {
                    base = version
                    savedText = sentText
                }
                unconfirmed = null
            }
            if (current == savedText) return
            val bytes = format.encode(current)
            val params = JSONObject().put("path", path)
            base?.let { params.put("base", it) }
            try {
                base = link.call("files.write", params, bytes).result.getString("version")
                savedText = current
                error = null
                Log.d(TAG, "Saved $path")
            } catch (e: MachineError) {
                when (e.code) {
                    "conflict" -> {
                        val version = if (e.details.has("version")) e.details.getString("version") else null
                        val theirs = version?.let { NoteFormat.decode(e.bytes)?.first ?: String(e.bytes) }
                        if (theirs == current) {
                            base = version
                            savedText = current
                        } else {
                            conflict = NoteConflict(theirs, version)
                        }
                    }
                    "disconnected" -> unconfirmed = current to contentVersion(bytes)
                    "offline" -> {}
                    else -> error = e.message
                }
            }
        } catch (e: MachineError) {
            Log.d(TAG, "Cannot check an earlier save of $path: ${e.code}")
        } finally {
            saving = false
        }
        if (text.text.toString() == savedText) withContext(Dispatchers.IO) { recovery.delete(machine, path) }
    }

    // Overwrites the Machine's version with this phone's text.
    fun keepMine() {
        val found = conflict ?: return
        base = found.version
        savedText = found.theirs
        conflict = null
    }

    // Drops this phone's text for the Machine's version. A deleted file closes.
    suspend fun useTheirs() {
        val found = conflict ?: return
        withContext(Dispatchers.IO) { recovery.delete(machine, path) }
        conflict = null
        if (found.theirs == null) {
            status = NoteStatus.Failed("The file was deleted on the Machine")
            return
        }
        base = found.version
        savedText = found.theirs
        replaceText(found.theirs)
    }

    // Shows a change that the Machine made, while this phone has no unsaved text.
    suspend fun refresh() {
        if (status != NoteStatus.Ready || dirty || saving || conflict != null || link.state != LinkState.Online) return
        try {
            val stats = link.call("files.stat", JSONObject().put("paths", JSONArray().put(path))).bytes
            val now = JSONArray(String(stats)).optJSONObject(0)?.let { "${it.opt("size")}:${it.opt("modified")}" }
            if (now == stat) return
            val reply = link.call("files.read", JSONObject().put("path", path))
            stat = now
            val version = reply.result.getString("version")
            if (version == base || dirty || saving || conflict != null) return
            val (fileText, fileFormat) = NoteFormat.decode(reply.bytes) ?: return
            base = version
            savedText = fileText
            format = fileFormat
            replaceText(fileText)
        } catch (e: MachineError) {
            Log.d(TAG, "Cannot check $path for changes: ${e.code}")
        }
    }

    private fun replaceText(value: String) {
        if (text.text.toString() == value) return
        val selection = text.selection
        text.edit {
            replace(0, length, value)
            this.selection = TextRange(minOf(selection.start, value.length), minOf(selection.end, value.length))
        }
    }
}

// The open notes of all Machines. A note stays open after its screen closes, so its unsaved text still saves.
class Notes(private val recovery: RecoveryStore, private val scope: CoroutineScope) {
    private val open = mutableMapOf<Pair<String, String>, Note>()

    fun open(link: MachineLink, path: String): Note =
        open.getOrPut(link.record.machine to path) { Note(link, path, recovery, scope) }

    // Opens each note with recovered text of this Machine, so its text saves without the user.
    suspend fun resume(link: MachineLink) {
        val records = withContext(Dispatchers.IO) { recovery.all(link.record.machine) }
        for (record in records) {
            Log.d(TAG, "Saving the recovered text of ${record.path}")
            open(link, record.path).load()
        }
    }

    // Saves each note with unsaved text now, such as before the connections close.
    suspend fun flush() {
        for (note in open.values.toList()) withContext(NonCancellable) { note.save() }
    }
}
