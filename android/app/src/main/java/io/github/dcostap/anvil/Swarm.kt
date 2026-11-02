package io.github.dcostap.anvil

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

sealed interface LinkState {
    data object Connecting : LinkState
    data object Online : LinkState
    data class Offline(val reason: String) : LinkState
}

// The connection to one paired Machine. While started, it connects again after each disconnect, with a growing
// delay up to 5 seconds, as the desktop Client does.
class MachineLink(
    val record: MachineRecord, private val scope: CoroutineScope, private val online: suspend (MachineLink) -> Unit,
) {
    var state by mutableStateOf<LinkState>(LinkState.Connecting)
        private set
    private var features: Set<String> = emptySet()

    // "full" when this phone can write files, from the last `hello`.
    var level by mutableStateOf("view")
        private set

    // The separator of the Machine's paths.
    var separator = "\\"
        private set
    private var connection: MachineConnection? = null
    private var job: Job? = null

    fun start() {
        if (job?.isActive == true) return
        job = scope.launch { run() }
    }

    fun stop() {
        job?.cancel()
        job = null
        connection?.close()
        connection = null
    }

    private suspend fun run() {
        var wait = 250L
        while (true) {
            try {
                val credentials = JSONObject().put("device", record.device).put("token", record.token)
                val (opened, hello) = MachineConnection.open(record.host, record.port, credentials)
                val list = hello.optJSONArray("features")
                features = (0 until (list?.length() ?: 0)).map { list!!.getString(it) }.toSet()
                level = hello.optString("level", "view")
                separator = if (hello.optString("os") == "Windows") "\\" else "/"
                connection = opened
                state = LinkState.Online
                wait = 250L
                scope.launch { online(this@MachineLink) }
                opened.closed.await()
                state = LinkState.Connecting
            } catch (e: MachineError) {
                state = LinkState.Offline(e.message ?: e.code)
            }
            connection = null
            delay(wait)
            wait = minOf(wait * 2, 5000L)
        }
    }

    suspend fun request(method: String, params: JSONObject = JSONObject()): JSONObject = call(method, params).result

    suspend fun call(method: String, params: JSONObject = JSONObject(), bytes: ByteArray = ByteArray(0)): MachineReply {
        val open = connection ?: throw MachineError("offline", "The Machine is not connected")
        return open.call(method, params, bytes)
    }

    // The Machine's Projects, each with its running Terminal Sessions, newest first.
    suspend fun overview(): List<Project> = coroutineScope {
        val list = request("projects.list").optJSONArray("projects")
        val listsTerminals = "terminal.list" in features
        (0 until (list?.length() ?: 0)).map { i ->
            val item = list!!.getJSONObject(i)
            val path = item.getString("path")
            async {
                Project(path, item.optBoolean("scratch"), if (listsTerminals) terminals(path) else emptyList())
            }
        }.awaitAll()
    }

    private suspend fun terminals(project: String): List<Terminal> {
        val sessions = try {
            request("terminal.list", JSONObject().put("project", project)).optJSONArray("sessions")
        } catch (e: MachineError) {
            if (e.code == "offline" || e.code == "disconnected") throw e
            Log.d("AnvilMachine", "No Terminal Sessions for $project: ${e.code}")
            null
        }
        return (0 until (sessions?.length() ?: 0)).map { Terminal.from(sessions!!.getJSONObject(it)) }
    }
}

data class Project(val path: String, val scratch: Boolean, val terminals: List<Terminal>) {
    val name: String get() = if (scratch) "Scratch" else path.trimEnd('/', '\\').substringAfterLast('/').substringAfterLast('\\')
}

// A running Terminal Session, from its record on the Machine. Times are Unix seconds, or 0.
data class Terminal(
    val id: String, val title: String, val busy: Boolean?, val agentState: String, val agentMessage: String,
    val agentStep: String, val agentModel: String, val agentSince: Long,
) {
    companion object {
        fun from(item: JSONObject) = Terminal(
            id = item.optString("id"), title = item.optString("title"),
            // The record keeps `busy` as 1 or 0. It has no value while the host has not reported yet.
            busy = (item.opt("busy") as? Number)?.let { it.toInt() == 1 },
            agentState = item.optString("agent_state"), agentMessage = item.optString("agent_message"),
            agentStep = item.optString("agent_step"), agentModel = item.optString("agent_model"),
            agentSince = item.optLong("agent_since"),
        )
    }
}

// All paired Machines and their open notes. The connections run between `start` and `stop`, while the app shows.
class Swarm(context: Context) {
    private val store = MachineStore(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var started = false
    private var stopping: Job? = null
    val notes = Notes(RecoveryStore(context), scope)
    val links = mutableStateListOf<MachineLink>().apply { addAll(store.load().map { link(it) }) }

    // A Machine that comes online gets the recovered text of its notes.
    private fun link(record: MachineRecord) = MachineLink(record, scope) { notes.resume(it) }

    fun start() {
        started = true
        stopping?.cancel()
        links.forEach { it.start() }
    }

    // Unsaved notes get up to 5 seconds to save before the connections close.
    fun stop() {
        started = false
        stopping = scope.launch {
            withTimeoutOrNull(5000) { notes.flush() }
            if (!started) links.forEach { it.stop() }
        }
    }

    fun close() = scope.cancel()

    // Pairs this phone with the Machine at `host:port` through its pairing code. Pairing the same Machine again
    // replaces its record.
    suspend fun pair(host: String, port: Int, code: String, name: String): MachineLink {
        val (connection, hello) = MachineConnection.open(host, port, JSONObject().put("pair", code).put("name", name))
        connection.close()
        val device = hello.optJSONObject("device") ?: throw MachineError("invalid_reply", "The Machine sent no device token")
        val record = MachineRecord(hello.getString("machine"), host, port, device.getString("id"), device.getString("token"))
        val replaced = links.filter { it.record.machine == record.machine }
        val records = links.filter { it !in replaced }.map { it.record } + record
        withContext(Dispatchers.IO) { store.save(records) }
        replaced.forEach {
            it.stop()
            links.remove(it)
        }
        val link = link(record)
        links.add(link)
        if (started) link.start()
        return link
    }
}
