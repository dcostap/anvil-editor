package io.github.dcostap.anvil

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

// Seam: the JNI boundary. The shared C modules count UTF-8 bytes, and Android counts UTF-16 units.
// Accents take two UTF-8 bytes and one UTF-16 unit. The emoji takes four bytes and two units.
@RunWith(AndroidJUnit4::class)
class MarkdownStylesTest {
    private val text = """
        # Canción 🎉

        Un **niño**, *año*, ~~viejo~~ y `código` 🎉 con [[Año|año nuevo]], [enlace](https://a.es/#x) y ==luz== #idea

        > cita

        - [x] hecho
        - nada

        ```lua
        **no**
        ```
    """.trimIndent() + "\n"
    private val spans = MarkdownStyles.spans(text)

    private fun texts(kind: Int) = spans.filter { it.kind == kind }.map { text.substring(it.start, it.end) }

    // Each element of the kind, with the text that stays visible while the caret is outside it.
    private fun shown(kind: Int) = spans.withIndex().filter { it.value.kind == kind }.map { (index, element) ->
        val hidden = spans.filter { it.kind == MarkdownSpan.MARKER && it.owner == index }
        (element.start until element.end).filter { at -> hidden.none { at >= it.start && at < it.end } }
            .joinToString("") { text[it].toString() }
    }

    @Test
    fun reportsElementsAndHidesTheirSyntaxInUtf16Units() {
        assertEquals(listOf("# Canción 🎉"), texts(1))
        assertEquals(listOf("Canción 🎉"), shown(1))
        assertEquals(listOf("niño"), shown(MarkdownSpan.BOLD))
        assertEquals(listOf("año"), shown(MarkdownSpan.ITALIC))
        assertEquals(listOf("viejo"), shown(MarkdownSpan.STRIKE))
        assertEquals(listOf("código"), shown(MarkdownSpan.CODE))
        assertEquals(listOf("año nuevo"), shown(MarkdownSpan.WIKILINK))
        assertEquals(listOf("enlace"), shown(MarkdownSpan.LINK))
        assertEquals(listOf("luz"), shown(MarkdownSpan.HIGHLIGHT))
        // The link's `#x` is not a tag.
        assertEquals(listOf("#idea"), texts(MarkdownSpan.TAG))
        assertEquals(listOf("> cita"), texts(MarkdownSpan.QUOTE))
        assertEquals(listOf("hecho"), texts(MarkdownSpan.TASK_DONE).map { it.trim() })
        assertEquals(listOf("```lua\n**no**\n```"), texts(MarkdownSpan.CODE_BLOCK))
    }
}
