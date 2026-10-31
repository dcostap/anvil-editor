package io.github.dcostap.anvil

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

// Seam: the JNI boundary. The shared C modules count UTF-8 bytes, and Android counts UTF-16 units.
// Accents take two UTF-8 bytes and one UTF-16 unit. The emoji takes four bytes and two units.
@RunWith(AndroidJUnit4::class)
class MarkdownStylesTest {
    private val text = "# Canción 🎉\n\nUn **niño** y [[Año|año nuevo]] 🎉 **fin**\n"
    private val spans = MarkdownStyles.spans(text)

    private fun elements(kind: Int) =
        spans.withIndex().filter { it.value.kind == kind }

    private fun markers(owner: Int) =
        spans.filter { it.kind == MarkdownSpan.MARKER && it.owner == owner }
            .sortedBy { it.start }
            .joinToString("") { text.substring(it.start, it.end) }

    @Test
    fun reportsHeadingsBoldTextAndWikilinksInUtf16Units() {
        val heading = elements(1).single()
        assertEquals("# Canción 🎉", text.substring(heading.value.start, heading.value.end))
        assertEquals("# ", markers(heading.index))

        val bold = elements(MarkdownSpan.BOLD)
        assertEquals(listOf("**niño**", "**fin**"), bold.map { text.substring(it.value.start, it.value.end) })
        assertEquals("********", bold.joinToString("") { markers(it.index) })

        val link = elements(MarkdownSpan.WIKILINK).single()
        assertEquals("[[Año|año nuevo]]", text.substring(link.value.start, link.value.end))
        assertEquals("[[Año|]]", markers(link.index))
    }
}
