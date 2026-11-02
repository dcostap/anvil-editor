package io.github.dcostap.anvil

import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

// Edits the notes of a real Machine server. `tests/lua/companion/machines.lua` makes the Project and passes
// `host`, `port`, `code` and `project` as runner arguments. A second connection plays the PC.
@RunWith(AndroidJUnit4::class)
class NotesTest {
    @get:Rule
    val rule = createEmptyComposeRule()

    private fun path(name: String) = project + "\\" + name

    private fun disk(path: String) = runBlocking { String(pc.call("files.read", JSONObject().put("path", path)).bytes) }

    private fun waitForDisk(path: String, expected: String) {
        rule.waitUntil(20_000) { disk(path) == expected }
    }

    private fun waitForText(text: String) {
        rule.waitUntil(20_000) { rule.onAllNodes(hasText(text)).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun openProject() {
        waitForText(record.host)
        rule.onNodeWithText(record.host).performClick()
        val name = project.substringAfterLast('\\')
        waitForText(name)
        rule.onNodeWithText(name).performClick()
    }

    private fun keep(name: String, base: String, text: String) = RecoveryStore(context)
        .save(Recovery(record.machine, path(name), contentVersion(base.toByteArray()), text, NoteFormat(false, false)))

    @Test
    fun savesAnEditWithTheFileLineEndings() {
        ActivityScenario.launch(MainActivity::class.java).use {
            openProject()
            waitForText("Notas")
            rule.onNodeWithText("Notas").performClick()
            waitForText("Dia")
            rule.onNodeWithText("Dia").performClick()
            rule.waitUntil(20_000) { rule.onAllNodes(hasTestTag("note")).fetchSemanticsNodes().isNotEmpty() }
            rule.onNodeWithTag("note").performTextReplacement("# Día\n\nUn **niño** y [[Año]]. Más\n")
            waitForDisk(path("Notas\\Dia.md"), "# Día\r\n\r\nUn **niño** y [[Año]]. Más\r\n")
        }
    }

    @Test
    fun asksAboutAChangeOnTheMachineAndKeepsMine() {
        // The phone's text started from "antes", but the Machine now has "suyo".
        keep("conflict.md", "antes\n", "mío\n")
        ActivityScenario.launch(MainActivity::class.java).use {
            openProject()
            waitForText("conflict")
            rule.onNodeWithText("conflict").performClick()
            waitForText("Changed on the Machine")
            rule.onNodeWithText("Keep mine").performClick()
            waitForDisk(path("conflict.md"), "mío\n")
        }
    }

    @Test
    fun savesTextFromAnEarlierRunWhenTheMachineConnects() {
        keep("recovered.md", "antes\n", "después\n")
        ActivityScenario.launch(MainActivity::class.java).use {
            waitForDisk(path("recovered.md"), "después\n")
            rule.waitUntil(5_000) { RecoveryStore(context).load(record.machine, path("recovered.md")) == null }
        }
    }

    companion object {
        private val arguments = InstrumentationRegistry.getArguments()
        private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
        private lateinit var record: MachineRecord
        private lateinit var pc: MachineConnection
        private lateinit var project: String

        @BeforeClass
        @JvmStatic
        fun pair() = runBlocking {
            val host = arguments.getString("host")
            assumeTrue("Run through tests/lua/companion/machines.lua", host != null)
            val port = arguments.getString("port")!!.toInt()
            val (pairing, hello) = MachineConnection.open(host!!, port,
                JSONObject().put("pair", arguments.getString("code")).put("name", "NotesTest"))
            pairing.close()
            val device = hello.getJSONObject("device")
            record = MachineRecord(hello.getString("machine"), host, port, device.getString("id"), device.getString("token"))
            val store = MachineStore(context)
            store.save(store.load().filter { it.machine != record.machine } + record)
            pc = MachineConnection.open(host, port, JSONObject().put("device", record.device).put("token", record.token)).first
            val projects = pc.request("projects.list").getJSONArray("projects")
            project = (0 until projects.length()).map { projects.getJSONObject(it).getString("path") }
                .single { it.substringAfterLast('\\') == arguments.getString("project") }
        }

        @AfterClass
        @JvmStatic
        fun forget() {
            if (!::record.isInitialized) return
            pc.close()
            val store = MachineStore(context)
            store.save(store.load().filter { it.machine != record.machine })
            val recovery = RecoveryStore(context)
            recovery.all(record.machine).forEach { recovery.delete(it.machine, it.path) }
        }
    }
}
