package io.github.dcostap.anvil

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.text.TextLayoutResult
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

// Seam: touch input on the note editor, with the emulator's real keyboard.
@RunWith(AndroidJUnit4::class)
class NoteEditorTouchTest {
    @get:Rule
    val rule = createAndroidComposeRule<MainActivity>()

    private fun editor() = rule.onNode(hasSetTextAction())

    private fun layout(): TextLayoutResult {
        val results = mutableListOf<TextLayoutResult>()
        editor().fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult].action!!(results)
        return results.first()
    }

    private fun selection() = editor().fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange]

    private fun tap(point: Offset) {
        editor().performTouchInput { click(point) }
        rule.waitForIdle()
    }

    @Test
    fun keyboardDoesNotCoverTheTappedLine() {
        val window = rule.activity.window.decorView
        fun keyboardHeight() = ViewCompat.getRootWindowInsets(window)?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0
        fun caretBottom(): Float {
            val top = editor().fetchSemanticsNode().positionInRoot.y
            return top + layout().getCursorRect(selection().end).bottom
        }

        // Tap the last line that shows before the keyboard opens.
        val node = editor().fetchSemanticsNode()
        val visibleBottom = node.boundsInRoot.bottom - node.positionInRoot.y
        val text = layout()
        val line = text.getLineForVerticalPosition(visibleBottom) - 1
        tap(Offset(text.getLineLeft(line) + 10f, (text.getLineTop(line) + text.getLineBottom(line)) / 2))

        rule.waitUntil("the keyboard opens", 10_000) { keyboardHeight() > 0 }
        rule.waitUntil("the caret shows above the keyboard", 5_000) {
            caretBottom() <= window.height - keyboardHeight()
        }
    }
}
