package io.github.dcostap.anvil

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

private class Entry(val name: String, val folder: Boolean)

private fun isNote(name: String) = name.endsWith(".md", ignoreCase = true) || name.endsWith(".markdown", ignoreCase = true)

private fun noteName(path: String) = path.substringAfterLast('/').substringAfterLast('\\').substringBeforeLast('.')

// One folder of a Project: its folders, then its notes. Hidden entries, such as `.git`, do not show.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderScreen(
    link: MachineLink, path: String, name: String, back: () -> Unit,
    openFolder: (path: String, name: String) -> Unit, openNote: (path: String) -> Unit,
) {
    var entries by remember(path) { mutableStateOf<List<Entry>?>(null) }
    var error by remember(path) { mutableStateOf<String?>(null) }
    LaunchedEffect(path, link.state) {
        if (link.state != LinkState.Online) return@LaunchedEffect
        try {
            val reply = link.call("files.list_dir", JSONObject().put("path", path))
            val list = JSONArray(String(reply.bytes))
            entries = (0 until list.length()).map { list.getJSONObject(it) }
                .map { Entry(it.getString("name"), it.optString("type") == "dir") }
                .filter { !it.name.startsWith(".") && (it.folder || isNote(it.name)) }
                .sortedWith(compareBy<Entry> { !it.folder }.thenBy { it.name.lowercase() })
            error = null
        } catch (e: MachineError) {
            error = e.message
        }
    }
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(name) }, navigationIcon = { TextButton(onClick = back) { Text("Back") } })
        },
    ) { padding ->
        LazyColumn(Modifier.padding(padding)) {
            if (link.state != LinkState.Online && entries == null) {
                item { ListItem(headlineContent = { Text("Connecting") }) }
            }
            error?.let { item { ListItem(headlineContent = { Text(it, color = MaterialTheme.colorScheme.error) }) } }
            items(entries.orEmpty(), key = { it.name }) { entry ->
                val child = path.trimEnd('/', '\\') + link.separator + entry.name
                ListItem(
                    headlineContent = { Text(if (entry.folder) entry.name else noteName(entry.name)) },
                    trailingContent = if (entry.folder) ({ Text("›") }) else null,
                    modifier = Modifier.clickable { if (entry.folder) openFolder(child, entry.name) else openNote(child) },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteScreen(note: Note, back: () -> Unit) {
    val scope = rememberCoroutineScope()
    val online = note.link.state == LinkState.Online
    LaunchedEffect(note, note.link.state) {
        if (note.status != NoteStatus.Ready) note.load()
    }
    // The Machine sends no change events for one file, so the open note checks it every 2 seconds.
    LaunchedEffect(note) {
        while (true) {
            delay(2000)
            note.refresh()
        }
    }
    val colors = MaterialTheme.colorScheme
    val preview = remember(colors) {
        LivePreview(MarkdownColors(link = colors.primary, syntax = colors.onSurfaceVariant,
            code = colors.surfaceVariant, highlight = colors.tertiaryContainer))
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(noteName(note.path)) },
                navigationIcon = { TextButton(onClick = back) { Text("Back") } },
                actions = {
                    val state = when {
                        note.status != NoteStatus.Ready -> null
                        note.link.level != "full" -> "Read only"
                        note.error != null -> note.error
                        note.dirty && !online -> "Offline"
                        note.dirty || note.saving -> "Saving"
                        else -> null
                    }
                    state?.let {
                        Text(it, color = if (it == note.error) colors.error else colors.onSurfaceVariant,
                            style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(end = 16.dp))
                    }
                },
            )
        },
    ) { padding ->
        when (val status = note.status) {
            NoteStatus.Loading -> Box(Modifier.padding(padding).fillMaxSize(), Alignment.Center) { Text("Loading") }
            is NoteStatus.Failed -> Box(Modifier.padding(padding).fillMaxSize(), Alignment.Center) {
                Text(status.message, color = colors.error, modifier = Modifier.padding(24.dp))
            }
            // The note scrolls outside the text field, and the padding is outside it too. So the field is as tall
            // as its text, and its coordinates are its text layout's.
            NoteStatus.Ready -> Box(
                Modifier
                    .padding(padding)
                    .consumeWindowInsets(padding)
                    .imePadding()
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 16.dp)
            ) {
                BasicTextField(
                    state = note.text,
                    readOnly = !note.editable,
                    outputTransformation = preview,
                    textStyle = TextStyle(fontSize = 17.sp, lineHeight = 1.5.em, color = colors.onSurface),
                    cursorBrush = SolidColor(colors.primary),
                    modifier = Modifier.fillMaxWidth().testTag("note").onFocusChanged { preview.focused = it.isFocused },
                )
            }
        }
    }
    note.conflict?.let { conflict ->
        AlertDialog(
            onDismissRequest = {},
            title = { Text(if (conflict.theirs == null) "Deleted on the Machine" else "Changed on the Machine") },
            text = { Text("This phone has changes that the Machine does not have.") },
            confirmButton = { TextButton(onClick = { note.keepMine() }) { Text("Keep mine") } },
            dismissButton = {
                TextButton(onClick = { scope.launch { note.useTheirs() } }) {
                    Text(if (conflict.theirs == null) "Discard mine" else "Use theirs")
                }
            },
        )
    }
}
