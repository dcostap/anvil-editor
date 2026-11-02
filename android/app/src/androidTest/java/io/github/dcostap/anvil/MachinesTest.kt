package io.github.dcostap.anvil

import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

// Pairs with a real Machine server and reads its Projects and Agent Status. `tests/lua/companion/machines.lua`
// starts the server and passes `host`, `port`, `code` and `project` as runner arguments.
@RunWith(AndroidJUnit4::class)
class MachinesTest {
    @get:Rule
    val rule = createAndroidComposeRule<MainActivity>()

    private val arguments = InstrumentationRegistry.getArguments()
    private val host = arguments.getString("host")
    private val port = arguments.getString("port")

    @After
    fun forgetMachine() {
        if (host == null) return
        val store = MachineStore(InstrumentationRegistry.getInstrumentation().targetContext)
        store.save(store.load().filter { it.host != host || it.port.toString() != port })
    }

    @Test
    fun pairsAndShowsTheAgentStatusOfEachProject() {
        assumeTrue("Run through tests/lua/companion/machines.lua", host != null)
        rule.onNodeWithText("Pair a Machine").performClick()
        rule.onNodeWithTag("host").performTextReplacement(host!!)
        rule.onNodeWithTag("port").performTextReplacement(port!!)
        rule.onNodeWithTag("code").performTextReplacement(arguments.getString("code")!!)
        rule.onNodeWithText("Pair").performClick()
        val project = arguments.getString("project")!!
        rule.waitUntil(20_000) { rule.onAllNodes(hasText(project)).fetchSemanticsNodes().isNotEmpty() }
        rule.waitUntil(20_000) {
            rule.onAllNodes(hasText("Waiting for you", substring = true)).fetchSemanticsNodes().isNotEmpty()
        }
        rule.onNodeWithText("Waiting for you · Approve the edit").assertExists()
    }
}
