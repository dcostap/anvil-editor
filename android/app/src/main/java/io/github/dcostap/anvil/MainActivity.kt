package io.github.dcostap.anvil

import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private lateinit var swarm: Swarm

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        swarm = Swarm(MachineStore(this))
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                Companion(swarm)
            }
        }
    }

    // The connections run only while the app shows.
    override fun onStart() {
        super.onStart()
        swarm.start()
    }

    override fun onStop() {
        swarm.stop()
        super.onStop()
    }

    override fun onDestroy() {
        swarm.close()
        super.onDestroy()
    }
}

private sealed interface Screen {
    data object Machines : Screen
    data object Pair : Screen
    data class Machine(val link: MachineLink) : Screen
}

@Composable
private fun Companion(swarm: Swarm) {
    var screen by remember { mutableStateOf<Screen>(Screen.Machines) }
    BackHandler(screen != Screen.Machines) { screen = Screen.Machines }
    when (val shown = screen) {
        Screen.Machines -> MachinesScreen(swarm, open = { screen = Screen.Machine(it) }, pair = { screen = Screen.Pair })
        Screen.Pair -> PairScreen(swarm, paired = { screen = Screen.Machine(it) }, back = { screen = Screen.Machines })
        is Screen.Machine -> MachineScreen(shown.link, back = { screen = Screen.Machines })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MachinesScreen(swarm: Swarm, open: (MachineLink) -> Unit, pair: () -> Unit) {
    Scaffold(
        topBar = { TopAppBar(title = { Text("Machines") }) },
        floatingActionButton = { ExtendedFloatingActionButton(onClick = pair) { Text("Pair a Machine") } },
    ) { padding ->
        LazyColumn(Modifier.padding(padding)) {
            items(swarm.links, key = { it.record.machine }) { link ->
                ListItem(
                    headlineContent = { Text(link.record.host) },
                    supportingContent = { LinkStateText(link.state) },
                    modifier = Modifier.clickable { open(link) },
                )
            }
        }
    }
}

@Composable
private fun LinkStateText(state: LinkState) {
    when (state) {
        LinkState.Connecting -> Text("Connecting")
        LinkState.Online -> Text("Online", color = MaterialTheme.colorScheme.primary)
        is LinkState.Offline -> Text(state.reason, color = MaterialTheme.colorScheme.error)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PairScreen(swarm: Swarm, paired: (MachineLink) -> Unit, back: () -> Unit) {
    var host by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("7690") }
    var code by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var pairing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val portNumber = port.toIntOrNull()?.takeIf { it in 1..65535 }
    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Pair a Machine") }, navigationIcon = { TextButton(onClick = back) { Text("Back") } })
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).padding(16.dp).fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(host, { host = it.trim() }, label = { Text("Host") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth().testTag("host"))
            OutlinedTextField(port, { port = it.filter(Char::isDigit) }, label = { Text("Port") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth().testTag("port"))
            OutlinedTextField(code, { code = it.filter(Char::isDigit).take(6) }, label = { Text("Pairing code") },
                singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                modifier = Modifier.fillMaxWidth().testTag("code"))
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(
                enabled = !pairing && host.isNotEmpty() && portNumber != null && code.length == 6,
                onClick = {
                    pairing = true
                    error = null
                    scope.launch {
                        try {
                            paired(swarm.pair(host, portNumber!!, code, Build.MODEL))
                        } catch (e: MachineError) {
                            error = e.message
                        } catch (e: Exception) {
                            error = "The pairing failed: ${e.message}"
                        } finally {
                            pairing = false
                        }
                    }
                },
            ) { Text(if (pairing) "Pairing" else "Pair") }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MachineScreen(link: MachineLink, back: () -> Unit) {
    var projects by remember { mutableStateOf<List<Project>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var now by remember { mutableStateOf(System.currentTimeMillis() / 1000) }
    // The Machine sends no change events for Terminal Sessions, so the screen lists them again every 2 seconds,
    // as the desktop does.
    LaunchedEffect(link, link.state) {
        while (link.state == LinkState.Online) {
            try {
                projects = link.overview()
                error = null
            } catch (e: MachineError) {
                error = e.message
            }
            now = System.currentTimeMillis() / 1000
            delay(2000)
        }
    }
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(link.record.host) }, navigationIcon = { TextButton(onClick = back) { Text("Back") } })
        },
    ) { padding ->
        LazyColumn(Modifier.padding(padding)) {
            if (link.state != LinkState.Online) item { ListItem(headlineContent = { LinkStateText(link.state) }) }
            error?.let { item { ListItem(headlineContent = { Text(it, color = MaterialTheme.colorScheme.error) }) } }
            for (project in projects.orEmpty()) {
                item(key = "project:" + project.path) {
                    HorizontalDivider()
                    ListItem(headlineContent = { Text(project.name, style = MaterialTheme.typography.titleMedium) })
                }
                items(project.terminals, key = { "terminal:" + it.id }) { terminal ->
                    TerminalRow(terminal, now)
                }
            }
        }
    }
}

@Composable
private fun TerminalRow(terminal: Terminal, now: Long) {
    val status = terminal.status(now)
    ListItem(
        headlineContent = { Text(terminal.title.ifEmpty { "Terminal" }) },
        supportingContent = status?.let { (text, tone) -> { Text(text, color = toneColor(tone)) } },
        trailingContent = if (terminal.agentModel.isEmpty()) null else ({ Text(terminal.agentModel) }),
        modifier = Modifier.padding(start = 16.dp),
    )
}

private enum class Tone { Normal, Warn, Error, Result }

@Composable
private fun toneColor(tone: Tone): Color = when (tone) {
    Tone.Normal -> MaterialTheme.colorScheme.onSurfaceVariant
    Tone.Warn -> Color(0xFFE08A00)
    Tone.Error -> MaterialTheme.colorScheme.error
    Tone.Result -> MaterialTheme.colorScheme.primary
}

// What the Terminal's agent does, as the desktop Sidebar's agent line says it. Without an agent, a running command
// shows as Running. Returns null when there is nothing to say.
private fun Terminal.status(now: Long): kotlin.Pair<String, Tone>? {
    val state = agentState.ifEmpty { if (agentStep.isNotEmpty()) "working" else "" }
    fun line(vararg parts: String) = parts.filter { it.isNotEmpty() }.joinToString(" · ")
    return when (state) {
        "blocked" -> line("Waiting for you", agentMessage) to Tone.Warn
        "working" -> line(agentStep.ifEmpty { agentMessage }.ifEmpty { "Working" },
            if (agentSince > 0) duration(now - agentSince) else "") to Tone.Normal
        "done" -> line("Done", agentMessage) to Tone.Result
        "error" -> line("Error", agentMessage) to Tone.Error
        "idle" -> "Idle" to Tone.Normal
        "" -> if (busy == true) "Running" to Tone.Normal else null
        else -> line(state, agentMessage) to Tone.Normal
    }
}

// A short duration such as "8s", "3m 05s" or "1h 20m", as the desktop shows it.
private fun duration(seconds: Long): String {
    val s = maxOf(0L, seconds)
    return when {
        s < 60 -> "${s}s"
        s < 3600 -> "%dm %02ds".format(s / 60, s % 60)
        else -> "%dh %02dm".format(s / 3600, s % 3600 / 60)
    }
}
