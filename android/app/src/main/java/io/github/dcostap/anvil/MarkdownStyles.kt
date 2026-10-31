package io.github.dcostap.anvil

import androidx.compose.foundation.text.input.OutputTransformation
import androidx.compose.foundation.text.input.TextFieldBuffer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** A styled range in UTF-16 units. A marker's owner is the index of its element. */
class MarkdownSpan(val kind: Int, val start: Int, val end: Int, val owner: Int) {
    companion object {
        const val BOLD = 7
        const val WIKILINK = 8
        const val MARKER = 9
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
        return List(items.size / 4) { i ->
            MarkdownSpan(items[i * 4], items[i * 4 + 1], items[i * 4 + 2], items[i * 4 + 3])
        }
    }
}

private val headingSizes = listOf(30.sp, 26.sp, 23.sp, 21.sp, 19.sp, 18.sp)
private val linkColor = Color(0xFF2F6FDE)
private val hidden = SpanStyle(fontSize = 0.01.sp, color = Color.Transparent, letterSpacing = 0.sp)

/**
 * Live Preview that only adds styles: the text stays the same, and markers are invisible
 * while the selection is outside their element. The keyboard so sees the real text.
 */
class LivePreview : OutputTransformation {
    private var text: String? = null
    private var spans = emptyList<MarkdownSpan>()

    override fun TextFieldBuffer.transformOutput() {
        val current = asCharSequence().toString()
        if (current != text) {
            text = current
            spans = MarkdownStyles.spans(current)
        }
        for (span in spans) {
            when (span.kind) {
                in 1..6 -> addStyle(
                    SpanStyle(fontSize = headingSizes[span.kind - 1], fontWeight = FontWeight.Bold), span.start, span.end
                )
                MarkdownSpan.BOLD -> addStyle(SpanStyle(fontWeight = FontWeight.Bold), span.start, span.end)
                MarkdownSpan.WIKILINK -> addStyle(SpanStyle(color = linkColor), span.start, span.end)
            }
        }
        // Markers come last, so they win over the styles of their elements.
        for (span in spans) {
            if (span.kind != MarkdownSpan.MARKER) continue
            val element = spans.getOrNull(span.owner) ?: continue
            val editing = selection.min <= element.end && selection.max >= element.start
            if (!editing) addStyle(hidden, span.start, span.end)
        }
    }
}
