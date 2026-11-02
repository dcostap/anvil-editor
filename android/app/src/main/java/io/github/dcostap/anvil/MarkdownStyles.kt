package io.github.dcostap.anvil

import androidx.compose.foundation.text.input.OutputTransformation
import androidx.compose.foundation.text.input.TextFieldBuffer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

// A styled range in UTF-16 units. A marker is syntax that hides while the selection is outside its element, the
// span at index `owner`. Keep the kinds in step with `markdown_styles.c`.
class MarkdownSpan(val kind: Int, val start: Int, val end: Int, val owner: Int) {
    companion object {
        const val BOLD = 7
        const val ITALIC = 8
        const val STRIKE = 9
        const val CODE = 10
        const val LINK = 11
        const val WIKILINK = 12
        const val HIGHLIGHT = 13
        const val TAG = 14
        const val CODE_BLOCK = 15
        const val QUOTE = 16
        const val LIST_MARKER = 17
        const val TASK_DONE = 18
        const val SYNTAX = 19
        const val TABLE = 20
        const val MARKER = 21
    }
}

object MarkdownStyles {
    init {
        System.loadLibrary("anvil_companion")
    }

    @JvmStatic
    private external fun scan(text: String): IntArray?

    fun spans(text: String): List<MarkdownSpan> {
        val items = scan(text) ?: return emptyList()
        return List(items.size / 4) { i -> MarkdownSpan(items[i * 4], items[i * 4 + 1], items[i * 4 + 2], items[i * 4 + 3]) }
    }
}

// The colours of Live Preview, from the app's colour scheme.
data class MarkdownColors(val link: Color, val syntax: Color, val code: Color, val highlight: Color)

// Live Preview that only adds styles. The text stays the same, so the keyboard always sees the real text. Markers
// get an invisible, almost zero-width style unless the focused field has its selection in their element.
class LivePreview(colors: MarkdownColors) : OutputTransformation {
    var focused by mutableStateOf(false)
    private var text: String? = null
    private var spans = emptyList<MarkdownSpan>()

    private val headings = listOf(1.6.em, 1.4.em, 1.25.em, 1.15.em, 1.08.em, 1.0.em)
        .map { SpanStyle(fontSize = it, fontWeight = FontWeight.Bold) }
    private val styles = mapOf(
        MarkdownSpan.BOLD to SpanStyle(fontWeight = FontWeight.Bold),
        MarkdownSpan.ITALIC to SpanStyle(fontStyle = FontStyle.Italic),
        MarkdownSpan.STRIKE to SpanStyle(textDecoration = TextDecoration.LineThrough),
        MarkdownSpan.CODE to SpanStyle(fontFamily = FontFamily.Monospace, background = colors.code),
        MarkdownSpan.LINK to SpanStyle(color = colors.link),
        MarkdownSpan.WIKILINK to SpanStyle(color = colors.link),
        MarkdownSpan.HIGHLIGHT to SpanStyle(background = colors.highlight),
        MarkdownSpan.TAG to SpanStyle(color = colors.link),
        MarkdownSpan.CODE_BLOCK to SpanStyle(fontFamily = FontFamily.Monospace, fontSize = 0.9.em, background = colors.code),
        MarkdownSpan.QUOTE to SpanStyle(color = colors.syntax, fontStyle = FontStyle.Italic),
        MarkdownSpan.LIST_MARKER to SpanStyle(color = colors.link, fontWeight = FontWeight.Bold),
        MarkdownSpan.TASK_DONE to SpanStyle(color = colors.syntax),
        MarkdownSpan.SYNTAX to SpanStyle(color = colors.syntax),
        MarkdownSpan.TABLE to SpanStyle(fontFamily = FontFamily.Monospace, fontSize = 0.9.em),
    )
    private val hidden = SpanStyle(fontSize = 0.01.sp, color = Color.Transparent, letterSpacing = 0.sp)

    override fun TextFieldBuffer.transformOutput() {
        val current = asCharSequence().toString()
        if (current != text) {
            text = current
            // A parse runs for each change on the UI thread. Very large notes stay plain, so typing stays smooth.
            spans = if (current.length <= MAX_STYLED) MarkdownStyles.spans(current) else emptyList()
        }
        for (span in spans) {
            val style = if (span.kind in 1..6) headings[span.kind - 1] else styles[span.kind] ?: continue
            addStyle(style, span.start, span.end)
        }
        // Markers come last, so they win over the styles of their elements.
        for (span in spans) {
            if (span.kind != MarkdownSpan.MARKER) continue
            val element = spans.getOrNull(span.owner) ?: continue
            val editing = focused && selection.min <= element.end && selection.max >= element.start
            if (!editing) addStyle(hidden, span.start, span.end)
        }
    }

    private companion object {
        const val MAX_STYLED = 300_000
    }
}
